import db from "./helpers/db.js";

const insert = cycle => db.cycles.add(cycle);

const monthlyLogs = millis => {
  const date = new Date(millis);
  const firstDay = new Date(date.getFullYear(), date.getMonth(), 1, 0, 0, 0);
  const lastDay = new Date(date.getFullYear(), date.getMonth() + 1, 0, 23, 59, 59);

  return db.cycles.where("start").between(firstDay.getTime(), lastDay.getTime()).toArray();
};

const dailyLogs = millis => {
  const date = new Date(millis);
  const dayStart = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0);
  const dayEnd = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59, 59);

  return db.cycles.where("start").between(dayStart.getTime(), dayEnd.getTime()).toArray();
};

const fetch = (app, millis) => {
  const daily = dailyLogs(millis);
  const monthly = monthlyLogs(millis);

  Promise.all([daily, monthly]).then(vals => {
    app.ports.gotStatsLogs.send({ ts: millis, daily: vals[0], monthly: vals[1] });
  });
};

const del = (app, start) => {
  db.cycles.where("start").equals(start).delete().then(count => {
    if (count > 0) {
      fetch(app, start);
    } else {
      //@TODO: some error handling... probably flash msgs!
    }
  });
};

export default function (app) {
  app.ports.logCycle.subscribe(insert);
  app.ports.fetchLogs.subscribe(millis => fetch(app, millis));
  app.ports.deleteCycle.subscribe(start => del(app, start));
}
