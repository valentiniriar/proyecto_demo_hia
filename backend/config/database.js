const { Sequelize } = require('sequelize');

const sequelize = new Sequelize(
    process.env.DB_NAME,
    process.env.DB_USER,
    process.env.DB_PASS,
    {
        host: process.env.DB_HOST,
        port: process.env.DB_PORT || 5432,
        dialect: 'postgres',
        logging: false,
    }
);

if (process.env.NODE_ENV !== 'test') {
    sequelize.authenticate()
        .then(() => console.log('La base de datos está conectada a PostgreSQL'))
        .catch(err => console.error('Error al conectar a PostgreSQL:', err));
}

module.exports = sequelize;
