import { Component, EventEmitter, Input, Output } from '@angular/core';

// Navegación Anterior / Siguiente para los listados paginados (el backend no da total: solo hasMore).
@Component({
  selector: 'app-paginador',
  standalone: true,
  template: `
    <nav class="d-flex justify-content-between align-items-center px-4 py-3 border-top" aria-label="Paginación">
      <button type="button" class="btn btn-outline-secondary btn-sm"
              [disabled]="cargando || page <= 1" (click)="cambiarPagina.emit(page - 1)">
        ‹ Anterior
      </button>
      <span class="text-secondary small">Página {{ page }}</span>
      <button type="button" class="btn btn-outline-secondary btn-sm"
              [disabled]="cargando || !hasMore" (click)="cambiarPagina.emit(page + 1)">
        Siguiente ›
      </button>
    </nav>
  `
})
export class PaginadorComponent {
  @Input() page = 1;
  @Input() hasMore = false;
  @Input() cargando = false;
  @Output() cambiarPagina = new EventEmitter<number>();
}
