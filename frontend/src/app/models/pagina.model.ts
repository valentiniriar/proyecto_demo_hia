// Respuesta de los listados paginados del backend (de a 20, sin total: hasMore indica si hay página siguiente).
export interface Pagina<T> {
  items: T[];
  page: number;
  limit: number;
  hasMore: boolean;
}
