import { Component, OnInit, ChangeDetectorRef } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ReactiveFormsModule, FormBuilder, FormGroup, Validators } from '@angular/forms';
import { SuscripcionService } from '../../services/suscripcion.service';
import { UsuarioService } from '../../services/usuario.service';
import { Suscripcion } from '../../models/suscripcion.model';
import { Usuario } from '../../models/usuario.model';
import { Pagina } from '../../models/pagina.model';
import { PaginadorComponent } from '../paginador/paginador.component';

@Component({
  selector: 'app-suscripciones-list',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule, PaginadorComponent],
  templateUrl: './suscripciones-list.component.html',
  styleUrl: './suscripciones-list.component.css'
})
export class SuscripcionesListComponent implements OnInit {

  suscripciones: Suscripcion[] = [];
  usuarios: Usuario[] = [];
  page: number = 1;
  hasMore: boolean = false;
  cargando: boolean = true;
  mensajeExito: string = '';
  mensajeError: string = '';

  suscripcionForm: FormGroup;
  modoEdicion: boolean = false;
  suscripcionSeleccionadaId: number | null = null;

  constructor(
    private suscripcionService: SuscripcionService,
    private usuarioService: UsuarioService,
    private fb: FormBuilder,
    private cdr: ChangeDetectorRef
  ) {
    this.suscripcionForm = this.fb.group({
      usuarioId: ['', Validators.required],
      fecha_inicio: ['', Validators.required],
      fecha_fin: ['', Validators.required],
      precio: ['', [Validators.required, Validators.min(0)]],
      activo: [true]
    });
  }

  ngOnInit(): void {
    this.buscarSocios();
    this.cargarSuscripciones();
  }

  cargarSuscripciones(page: number = this.page): void {
    this.cargando = true;
    this.suscripcionService.getSuscripciones(page).subscribe({
      next: (res: Pagina<Suscripcion>) => {
        this.suscripciones = res.items;
        this.page = res.page;
        this.hasMore = res.hasMore;
        this.cargando = false;
        this.cdr.detectChanges();
      },
      error: () => {
        this.cargando = false;
        this.mensajeError = 'Error al cargar las suscripciones.';
        this.cdr.detectChanges();
      }
    });
  }

  // Combo de socios: hay millones, así que se busca por DNI (sin DNI, los 20 más recientes).
  buscarSocios(dni: string = ''): void {
    this.usuarioService.getSocios(dni.trim()).subscribe({
      next: (res: any) => {
        if (res.status === '1') this.usuarios = res.usuarios;
        this.cdr.detectChanges();
      }
    });
  }

  // Al editar, el socio de la suscripción puede no estar entre los resultados del buscador.
  private asegurarSocioEnCombo(usuario?: Usuario): void {
    if (usuario && !this.usuarios.some(u => u.id === usuario.id)) {
      this.usuarios = [usuario, ...this.usuarios];
    }
  }

  abrirModalNuevo(): void {
    this.modoEdicion = false;
    this.suscripcionSeleccionadaId = null;
    
    const hoy = new Date();
    const proximoMes = new Date();
    proximoMes.setMonth(hoy.getMonth() + 1);
    
    this.suscripcionForm.reset({
      activo: true,
      usuarioId: '',
      fecha_inicio: hoy.toISOString().split('T')[0],
      fecha_fin: proximoMes.toISOString().split('T')[0],
      precio: ''
    });
  }

  abrirModalEditar(susc: Suscripcion): void {
    this.modoEdicion = true;
    this.suscripcionSeleccionadaId = susc.id;
    this.asegurarSocioEnCombo(susc.usuario);
    this.suscripcionForm.patchValue({
      usuarioId: susc.usuario?.id,
      fecha_inicio: susc.fecha_inicio,
      fecha_fin: susc.fecha_fin,
      precio: susc.precio,
      activo: susc.activo
    });
  }

  guardarSuscripcion(): void {
    if (this.suscripcionForm.invalid) return;

    const formVals = this.suscripcionForm.value;
    const datosParaBackend = {
      fecha_inicio: formVals.fecha_inicio,
      fecha_fin: formVals.fecha_fin,
      precio: String(formVals.precio),
      activo: formVals.activo,
      usuario: { id: Number(formVals.usuarioId) }
    };

    if (this.modoEdicion && this.suscripcionSeleccionadaId) {
      this.suscripcionService.editSuscripcion(this.suscripcionSeleccionadaId, datosParaBackend).subscribe({
        next: (response: any) => {
          if (response.status === '1') {
            this.mensajeExito = 'Suscripción actualizada.';
            this.cargarSuscripciones();
          } else { this.mensajeError = response.msg; }
          this.cdr.detectChanges();
        }
      });
    } else {
      this.suscripcionService.createSuscripcion(datosParaBackend).subscribe({
        next: (response: any) => {
          if (response.status === '1') {
            this.mensajeExito = 'Suscripción creada.';
            this.cargarSuscripciones();
          } else { this.mensajeError = response.msg; }
          this.cdr.detectChanges();
        }
      });
    }
  }

  cambiarEstado(susc: Suscripcion): void {
    const datos = {
      ...susc,
      activo: !susc.activo,
      usuario: { id: susc.usuario?.id }
    };
    
    this.suscripcionService.editSuscripcion(susc.id, datos).subscribe({
      next: (response: any) => {
        if (response.status === '1') {
          this.mensajeExito = `Suscripción ${datos.activo ? 'activada' : 'inactivada'}.`;
          this.cargarSuscripciones();
        }
        this.cdr.detectChanges();
      }
    });
  }

  eliminarSuscripcion(id: number): void {
    if (!confirm('¿Estás seguro de eliminar esta suscripción?')) return;

    this.suscripcionService.deleteSuscripcion(id).subscribe({
      next: (response: any) => {
        if (response.status === '1') {
          this.mensajeExito = 'Suscripción eliminada.';
          this.cargarSuscripciones();
        } else {
          this.mensajeError = response.msg;
        }
        this.cdr.detectChanges();
      },
      error: (err) => {
        if(err.error && err.error.msg) {
          this.mensajeError = err.error.msg;
        } else {
          this.mensajeError = 'Error al eliminar.';
        }
        this.cdr.detectChanges();
      }
    });
  }

  limpiarMensajes(): void {
    this.mensajeExito = '';
    this.mensajeError = '';
  }
}