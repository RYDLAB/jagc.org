db.task.update({}, {$rename: {"stat.s_all": "stat.all", "stat.s_ok": "stat.ok"}}, {multi: true});
