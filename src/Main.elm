port module Main exposing (main)

import Browser
import Colors
import Css
import Helpers
import Html.Styled as Html exposing (Html)
import Html.Styled.Attributes as HtmlAttr
import Html.Styled.Events as Event
import Json.Decode as D
import Json.Encode as E
import List.Extra as ListEx
import Model exposing (Model)
import Msg exposing (Msg(..))
import Platform exposing (Program)
import Platform.Sub as Sub
import Task
import Time exposing (Posix)
import Types exposing (Continuity(..), Current, Interval(..), Page(..), Spotify(..), Theme)
import View.Settings as Settings
import View.Timer as Timer


port notify : () -> Cmd msg


port persistCurrent : E.Value -> Cmd msg


port persistSettings : E.Value -> Cmd msg


port spotifyPlay : String -> Cmd msg


port spotifyPause : () -> Cmd msg


port spotifyRefresh : () -> Cmd msg


port spotifyDisconnect : () -> Cmd msg


port gotSpotifyState : (D.Value -> msg) -> Sub msg


type alias Flags =
    { current : D.Value
    , settings : D.Value
    }


init : Flags -> ( Model, Cmd Msg )
init { current, settings } =
    let
        baseModel =
            Model.default

        newCurrent =
            case D.decodeValue Model.decodeCurrent current of
                Ok curr ->
                    curr

                Err _ ->
                    baseModel.current

        newSettings =
            case D.decodeValue Model.decodeSettings settings of
                Ok settings_ ->
                    settings_

                Err _ ->
                    baseModel.settings

        ( newIntervals, newCurrent_ ) =
            Model.buildIntervals newSettings (Just newCurrent)
    in
    ( { baseModel | current = newCurrent_, settings = newSettings, intervals = newIntervals }
    , Task.perform AdjustTimeZone Time.here
    )


view : Model -> Html Msg
view model =
    Html.div
        [ HtmlAttr.class "container"
        , HtmlAttr.css
            [ Css.width <| Css.vw 100.0
            , Css.position Css.relative
            , Css.backgroundColor <| (model.settings.theme |> Colors.backgroundColor |> Colors.toCssColor)
            , Css.fontFamilies [ "Montserrat" ]
            , Css.color (model.settings.theme |> Colors.textColor |> Colors.toCssColor)
            ]
        ]
        [ renderPage model
        , renderNav model.settings.theme model.page
        ]


renderNav : Theme -> Page -> Html Msg
renderNav theme page =
    let
        pages =
            [ ( TimerPage, "timer" )
            , ( SettingsPage, "settings" )
            ]

        buttonStyle =
            Css.batch
                [ Css.borderStyle Css.none
                , Css.backgroundColor Css.transparent
                , Css.width <| Css.rem 3
                , Css.height <| Css.rem 3
                , Css.color <| (theme |> Colors.backgroundColor |> Colors.toCssColor)
                , Css.outline Css.zero
                , Css.cursor Css.pointer
                ]
    in
    Html.div
        [ HtmlAttr.css
            [ Css.position Css.absolute
            , Css.bottom <| Css.px 0
            , Css.left <| Css.px 0
            , Css.right <| Css.px 0
            , Css.backgroundColor <| (theme |> Colors.foregroundColor |> Colors.toCssColor)
            , Css.color <| (theme |> Colors.foregroundColor |> Colors.toCssColor)
            , Css.displayFlex
            , Css.justifyContent Css.center
            , Css.padding <| Css.rem 0.25
            ]
        ]
        [ Html.ul
            [ HtmlAttr.css
                [ Css.displayFlex
                , Css.justifyContent Css.center
                , Css.listStyle Css.none
                ]
            ]
            (pages
                |> List.map
                    (\( page_, icon ) ->
                        Html.li []
                            [ Html.button
                                [ Event.onClick <| ChangePage page_
                                , HtmlAttr.css
                                    [ buttonStyle
                                    , if page_ == page then
                                        Css.opacity <| Css.num 1

                                      else
                                        Css.opacity <| Css.num 0.4
                                    ]
                                ]
                                [ Helpers.icon icon ]
                            ]
                    )
            )
        ]


renderPage : Model -> Html Msg
renderPage model =
    Html.div [ HtmlAttr.css [ Css.height (Css.calc (Css.pct 100) Css.minus (Css.rem 3.5)), Css.overflow Css.auto ] ]
        [ case model.page of
            TimerPage ->
                Timer.render model

            SettingsPage ->
                Settings.render model

            _ ->
                Html.text "other pages"
        ]


evalElapsedTime : Posix -> Spotify -> Current -> Continuity -> List Interval -> ( Current, Bool, Cmd msg )
evalElapsedTime now spotify current repeat intervals =
    if Model.currentSecondsLeft current == 0 then
        let
            firstInterval =
                intervals |> Model.firstInterval

            nextIdx =
                current.index + 1

            cmdFnByInterval interval =
                case ( interval, spotify ) of
                    ( Activity _, Connected _ (Just uri) ) ->
                        spotifyPlay uri

                    ( _, Connected _ (Just _) ) ->
                        spotifyPause ()

                    _ ->
                        Cmd.none

            ( current_, playing ) =
                case ( intervals |> ListEx.getAt nextIdx, repeat ) of
                    ( Nothing, FullCont ) ->
                        ( Current 0 (Model.cycleBuild firstInterval (Just now)) 0, True )

                    ( Nothing, _ ) ->
                        ( Current 0 (Model.cycleBuild firstInterval Nothing) 0, False )

                    ( Just nextInterval, NoCont ) ->
                        ( Current nextIdx (Model.cycleBuild nextInterval Nothing) 0, False )

                    ( Just nextInterval, _ ) ->
                        ( Current nextIdx (Model.cycleBuild nextInterval (Just now)) 0, True )
        in
        ( current_, playing, Cmd.batch [ notify (), cmdFnByInterval current_.cycle.interval ] )

    else
        ( Model.currentAddElapsed 1 current, True, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        done m =
            ( m, Cmd.none )

        playPlaylist uri ( model_, cmd ) =
            spotifyPlay uri
                |> Helpers.flip (::) [ cmd ]
                |> Cmd.batch
                |> Tuple.pair model_

        pausePlaylist ( model_, cmd ) =
            spotifyPause ()
                |> Helpers.flip (::) [ cmd ]
                |> Cmd.batch
                |> Tuple.pair model_

        persistCurrent_ ( model_, cmd ) =
            model_.current
                |> Model.encodeCurrent
                |> persistCurrent
                |> Helpers.flip (::) [ cmd ]
                |> Cmd.batch
                |> Tuple.pair model_

        persistSettings_ ( model_, cmd ) =
            model_.settings
                |> Model.encodeSettings
                |> persistSettings
                |> Helpers.flip (::) [ cmd ]
                |> Cmd.batch
                |> Tuple.pair model_

        updateSettings model_ =
            let
                ( newIntervals, newCurrent ) =
                    Model.buildIntervals model_.settings (Just model_.current)

                ( newLog, logCmd ) =
                    model.log |> Model.cycleLog model.time model.current
            in
            { model_ | current = newCurrent, log = newLog, intervals = newIntervals, playing = False }
                |> Helpers.flip Tuple.pair logCmd
                |> persistSettings_
                |> persistCurrent_
                |> pausePlaylist
    in
    case msg of
        NoOp ->
            done model

        Tick posix ->
            let
                updateTime model_ =
                    { model_ | time = posix, uptime = model_.uptime + 1 }
            in
            if model.playing == True then
                let
                    ( newCurrent, newPlaying, cmd ) =
                        evalElapsedTime model.time
                            model.settings.spotify
                            model.current
                            model.settings.continuity
                            model.intervals

                    ( newLog, logCmd ) =
                        if cmd /= Cmd.none then
                            model.log |> Model.cycleLog model.time model.current

                        else
                            ( model.log, Cmd.none )
                in
                { model | current = newCurrent, playing = newPlaying, log = newLog }
                    |> updateTime
                    |> Helpers.flip Tuple.pair (Cmd.batch [ cmd, logCmd ])
                    |> persistCurrent_

            else
                model |> updateTime |> done

        AdjustTimeZone newZone ->
            done { model | zone = newZone }

        Pause ->
            done { model | playing = False } |> pausePlaylist

        Play ->
            let
                { index, cycle, elapsed } =
                    model.current

                newCurrent =
                    if elapsed == 0 then
                        Current index (Model.cycleStart model.time cycle) 0

                    else
                        model.current

                cmdFn =
                    case ( model.settings.spotify, newCurrent.cycle.interval ) of
                        ( Connected _ (Just uri), Activity _ ) ->
                            playPlaylist uri

                        _ ->
                            identity
            in
            { model | playing = True, current = newCurrent } |> done |> persistCurrent_ |> cmdFn

        Skip ->
            let
                { index } =
                    model.current

                ( newIndex, newInterval ) =
                    case ListEx.getAt (index + 1) model.intervals of
                        Just next ->
                            ( index + 1, next )

                        Nothing ->
                            ( 0, model.intervals |> Model.firstInterval )

                newCurrent =
                    Current newIndex (Model.cycleBuild newInterval Nothing) 0

                ( newLog, logCmd ) =
                    model.log |> Model.cycleLog model.time model.current
            in
            { model | current = newCurrent, playing = False, log = newLog }
                |> Helpers.flip Tuple.pair logCmd
                |> persistCurrent_
                |> pausePlaylist

        Reset ->
            let
                ( newLog, logCmd ) =
                    model.log |> Model.cycleLog model.time model.current

                newCurrent =
                    Current 0 (Model.cycleBuild (Model.firstInterval model.intervals) Nothing) 0
            in
            { model | current = newCurrent, log = newLog, playing = False }
                |> Helpers.flip Tuple.pair logCmd
                |> persistCurrent_
                |> pausePlaylist

        SetCont cont ->
            model
                |> Model.mapSettings (\s -> { s | continuity = cont })
                |> done
                |> persistSettings_

        ChangeRounds rounds ->
            model
                |> Model.mapSettings (\s -> { s | rounds = rounds })
                |> updateSettings

        ChangeActivity mins ->
            model
                |> Model.mapSettings (\s -> { s | activity = mins * 60 })
                |> updateSettings

        ChangeBreak mins ->
            model
                |> Model.mapSettings (\s -> { s | break = mins * 60 })
                |> updateSettings

        ChangeLongBreak mins ->
            model
                |> Model.mapSettings (\s -> { s | longBreak = mins * 60 })
                |> updateSettings

        ChangeContinuity cont ->
            case Model.continuityFromString cont of
                Just c ->
                    model
                        |> Model.mapSettings (\s -> { s | continuity = c })
                        |> updateSettings

                Nothing ->
                    done model

        ChangeTheme theme ->
            case Model.themeFromString theme of
                Just t ->
                    model
                        |> Model.mapSettings (\s -> { s | theme = t })
                        |> updateSettings

                Nothing ->
                    done model

        ChangePage page ->
            done { model | page = page }

        ChangePlaylist uri ->
            model
                |> Model.mapSettings
                    (\s ->
                        let
                            newSpotify =
                                case s.spotify of
                                    Connected playlists _ ->
                                        Connected
                                            playlists
                                            (ListEx.find (Tuple.first >> (==) uri) playlists |> Maybe.map Tuple.first)

                                    _ ->
                                        s.spotify
                        in
                        { s | spotify = newSpotify }
                    )
                |> updateSettings

        GotSpotifyState raw ->
            case D.decodeValue Model.decodeSpotify raw of
                Ok newState ->
                    model
                        |> Model.mapSettings
                            (\s ->
                                let
                                    newSpotify =
                                        case ( s.spotify, newState ) of
                                            ( Connected _ (Just current), Connected playlists _ ) ->
                                                let
                                                    newCurrent =
                                                        playlists
                                                            |> ListEx.find (Tuple.first >> (==) current)
                                                            |> Maybe.map Tuple.first
                                                in
                                                Connected playlists newCurrent

                                            _ ->
                                                newState
                                in
                                { s | spotify = newSpotify }
                            )
                        |> updateSettings

                Err _ ->
                    done model

        SpotifyRefresh ->
            ( model, spotifyRefresh () )

        SpotifyDisconnect ->
            ( model, spotifyDisconnect () )


subs : Model -> Sub Msg
subs _ =
    Sub.batch
        [ Time.every 1000 Tick
        , gotSpotifyState GotSpotifyState
        ]


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , view = view >> Html.toUnstyled
        , update = update
        , subscriptions = subs
        }
