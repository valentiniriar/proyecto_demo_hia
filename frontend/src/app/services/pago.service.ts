import { environment } from '../../environments/environment';
import { Injectable } from '@angular/core';
import { HttpClient, HttpHeaders, HttpParams } from '@angular/common/http';
import { Observable } from 'rxjs';
import { LoginService } from './login.service';

@Injectable({
  providedIn: 'root'
})
export class PagoService {

  private hostBase = `${environment.apiUrl}/pagos/`;

  constructor(private _http: HttpClient, private loginService: LoginService) {}

  private getAuthHeaders(): { headers: HttpHeaders } {
    return {
      headers: new HttpHeaders({
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.loginService.getToken()}`
      })
    };
  }

  public getPagos(page: number = 1): Observable<any> {
    return this._http.get(this.hostBase, { ...this.getAuthHeaders(), params: new HttpParams().set('page', page) });
  }

  public createPago(datos: any): Observable<any> {
    const body = JSON.stringify(datos);
    return this._http.post(this.hostBase, body, this.getAuthHeaders());
  }

  public anularPago(id: number): Observable<any> {
    return this._http.patch(this.hostBase + id + '/anular', {}, this.getAuthHeaders());
  }
}
