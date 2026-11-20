import { environment } from '../../environments/environment';
import { Injectable } from '@angular/core';
import { HttpClient, HttpHeaders, HttpParams } from '@angular/common/http';
import { Observable } from 'rxjs';
import { LoginService } from './login.service';

@Injectable({
  providedIn: 'root'
})
export class UsuarioService {

  private hostBase = `${environment.apiUrl}/usuarios/`;

  constructor(private _http: HttpClient, private loginService: LoginService) {}

  private getAuthHeaders(): { headers: HttpHeaders } {
    return {
      headers: new HttpHeaders({
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.loginService.getToken()}`
      })
    };
  }

  public getUsuarios(page: number = 1): Observable<any> {
    return this._http.get(this.hostBase, { ...this.getAuthHeaders(), params: new HttpParams().set('page', page) });
  }

  // q: DNI del socio (para los buscadores de los combos). Sin q devuelve los 20 socios más recientes.
  public getSocios(q?: string): Observable<any> {
    const params = q ? new HttpParams().set('q', q) : new HttpParams();
    return this._http.get(this.hostBase + 'socios/list', { ...this.getAuthHeaders(), params });
  }

  public updateUsuario(dni: string, datos: any): Observable<any> {
    const body = JSON.stringify(datos);
    return this._http.put(this.hostBase + dni, body, this.getAuthHeaders());
  }

  public deleteUsuario(dni: string): Observable<any> {
    return this._http.delete(this.hostBase + dni, this.getAuthHeaders());
  }

  public inactivarUsuario(dni: string): Observable<any> {
    return this._http.patch(this.hostBase + `${dni}/inactive`, {}, this.getAuthHeaders());
  }

  public activarUsuario(dni: string): Observable<any> {
    return this._http.patch(this.hostBase + `${dni}/active`, {}, this.getAuthHeaders());
  }
}