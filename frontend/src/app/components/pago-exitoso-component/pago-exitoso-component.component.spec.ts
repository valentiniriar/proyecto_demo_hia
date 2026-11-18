import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideRouter } from '@angular/router';

import { PagoExitosoComponentComponent } from './pago-exitoso-component.component';

describe('PagoExitosoComponentComponent', () => {
  let component: PagoExitosoComponentComponent;
  let fixture: ComponentFixture<PagoExitosoComponentComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [PagoExitosoComponentComponent],
      providers: [provideRouter([]), provideHttpClient()],
    }).compileComponents();

    fixture = TestBed.createComponent(PagoExitosoComponentComponent);
    component = fixture.componentInstance;
    await fixture.whenStable();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
