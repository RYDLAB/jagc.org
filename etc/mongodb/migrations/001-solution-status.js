db.solution.update({s: 0}, {$set: {s: 'inactive' }}, {multi: true});
db.solution.update({s: 1}, {$set: {s: 'finished' }}, {multi: true});
db.solution.update({s: 2}, {$set: {s: 'incorrect'}}, {multi: true});
db.solution.update({s: 3}, {$set: {s: 'timeout'  }}, {multi: true});
db.solution.update({s: 4}, {$set: {s: 'error'    }}, {multi: true});
db.solution.update({s: 5}, {$set: {s: 'fail'     }}, {multi: true});
db.solution.update({s: 6}, {$set: {s: 'testing'  }}, {multi: true});
