db.user.update({}, {$set: {"notice.new": false}}, {multi: true});
