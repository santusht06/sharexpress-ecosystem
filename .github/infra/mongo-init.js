// MongoDB init script — runs once at first startup
// Creates the application user and database

db = db.getSiblingDB('sharexpress_cloud');

db.createUser({
  user: 'sharexpress_app',
  pwd: process.env.MONGO_APP_PASSWORD || 'changeme_app_password',
  roles: [
    { role: 'readWrite', db: 'sharexpress_cloud' },
    { role: 'dbAdmin', db: 'sharexpress_cloud' }
  ]
});

// Create initial collections with validators
db.createCollection('users');
db.createCollection('projects');
db.createCollection('deployments');
db.createCollection('workspaces');

print('MongoDB init complete: sharexpress_cloud database and app user created.');
