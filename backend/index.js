const app = require('./app');
const sequelize = require('./config/database');

app.set('port', process.env.PORT || 3000);

// Starting the database
sequelize.sync({ force: false })
    .then(() => {
        console.log('Tablas de PostgreSQL sincronizadas');

        app.listen(app.get('port'), () => {
            console.log(`Servidor iniciado en el puerto`, app.get('port'));
        });
    })
    .catch(err => {
        console.error('No se pudo iniciar el servidor debido a un error en la BD:', err);
    });
