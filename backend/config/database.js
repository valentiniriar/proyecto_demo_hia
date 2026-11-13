const { Sequelize } = require('sequelize');

let sequelizeConfig = {
    dialect: 'postgres',
    logging: false,
};

// Soporte de arquitectura replicada (SCRUM-47):
// Si se configuran DB_HOST_PRIMARY y DB_HOST_REPLICA, Sequelize enruta
// automáticamente las escrituras (INSERT, UPDATE, DELETE) al primario y
// distribuye las lecturas (SELECT) hacia la réplica.
if (process.env.DB_HOST_PRIMARY || process.env.DB_HOST_REPLICA) {
    sequelizeConfig.replication = {
        write: {
            host: process.env.DB_HOST_PRIMARY || process.env.DB_HOST || 'localhost',
            port: process.env.DB_PORT_PRIMARY || process.env.DB_PORT || 5432,
            username: process.env.DB_USER_PRIMARY || process.env.DB_USER,
            password: process.env.DB_PASS_PRIMARY || process.env.DB_PASS,
            database: process.env.DB_NAME,
        },
        read: [
            {
                host: process.env.DB_HOST_REPLICA || process.env.DB_HOST || 'localhost',
                port: process.env.DB_PORT_REPLICA || 5434,
                username: process.env.DB_USER_REPLICA || process.env.DB_USER,
                password: process.env.DB_PASS_REPLICA || process.env.DB_PASS,
                database: process.env.DB_NAME,
            }
        ]
    };
} else {
    // Configuración estándar de nodo único
    sequelizeConfig.host = process.env.DB_HOST || 'localhost';
    sequelizeConfig.port = process.env.DB_PORT || 5432;
    sequelizeConfig.username = process.env.DB_USER;
    sequelizeConfig.password = process.env.DB_PASS;
    sequelizeConfig.database = process.env.DB_NAME;
}

const sequelize = new Sequelize(
    sequelizeConfig.database,
    sequelizeConfig.username,
    sequelizeConfig.password,
    sequelizeConfig
);

if (process.env.NODE_ENV !== 'test') {
    sequelize.authenticate()
        .then(() => console.log('La base de datos está conectada a PostgreSQL'))
        .catch(err => console.error('Error al conectar a PostgreSQL:', err));
}

module.exports = sequelize;
