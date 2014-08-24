db.language.remove({name: 'ruby1.8'});
db.language.remove({name: 'nodejs'});
db.solution.update({lng: 'ruby1.8'}, {$set: {lng: 'ruby1.9' }}, {multi: true});
