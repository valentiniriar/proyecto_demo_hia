// Paginación de listados: las tablas tienen millones de filas y traerlas todas cuelga backend y navegador.
// Se pide limit + 1 filas: si vuelve una de más, hay página siguiente (sin COUNT(*), que con ~6M filas tarda segundos).
const LIMITE_POR_DEFECTO = 20;
const LIMITE_MAXIMO = 100;

const enteroPositivo = (valor, porDefecto) => {
    const n = Number.parseInt(valor, 10);
    return Number.isInteger(n) && n > 0 ? n : porDefecto;
};

const leerPaginacion = (req) => {
    const page = enteroPositivo(req.query?.page, 1);
    const limit = Math.min(enteroPositivo(req.query?.limit, LIMITE_POR_DEFECTO), LIMITE_MAXIMO);
    return { page, limit, offset: (page - 1) * limit };
};

// Opciones para findAll: una fila extra para saber si hay más, y orden estable por PK (lo más nuevo primero).
const opcionesConsulta = ({ limit, offset }) => ({
    limit: limit + 1,
    offset,
    order: [['id', 'DESC']],
});

const armarPagina = (filas, { page, limit }) => ({
    items: filas.slice(0, limit),
    page,
    limit,
    hasMore: filas.length > limit,
});

// Texto de búsqueda (?q=) recortado; vacío → null.
const leerBusqueda = (req) => {
    const q = typeof req.query?.q === 'string' ? req.query.q.trim().slice(0, 100) : '';
    return q || null;
};

module.exports = {
    leerPaginacion, opcionesConsulta, armarPagina, leerBusqueda,
    LIMITE_POR_DEFECTO, LIMITE_MAXIMO,
};
