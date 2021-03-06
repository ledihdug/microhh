/*
 * MicroHH
 * Copyright (c) 2011-2017 Chiel van Heerwaarden
 * Copyright (c) 2011-2017 Thijs Heus
 * Copyright (c) 2014-2017 Bart van Stratum
 *
 * This file is part of MicroHH
 *
 * MicroHH is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.

 * MicroHH is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with MicroHH.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <cstdio>
#include "grid.h"
#include "fields.h"
#include "thermo_vapor.h"
#include "defines.h"
#include "constants.h"
#include "finite_difference.h"
#include "master.h"
#include "tools.h"
#include "thermo_moist_functions.h"

namespace 
{
    using namespace Constants;
    using namespace Finite_difference::O2;
    using namespace Finite_difference::O4;
    using namespace Thermo_moist_functions;

    __global__ 
    void calc_buoyancy_tend_2nd_g(double* __restrict__ wt, double* __restrict__ th, double* __restrict__ qt,
                                  double* __restrict__ thvrefh, double* __restrict__ exnh, double* __restrict__ ph,  
                                  int istart, int jstart, int kstart,
                                  int iend,   int jend,   int kend,
                                  int jj, int kk)
    {
        const int i = blockIdx.x*blockDim.x + threadIdx.x + istart; 
        const int j = blockIdx.y*blockDim.y + threadIdx.y + jstart; 
        const int k = blockIdx.z + kstart; 

        if (i < iend && j < jend && k < kend)
        {
            const int ijk = i + j*jj + k*kk;

            // Half level temperature and moisture content
            const double thh = 0.5 * (th[ijk-kk] + th[ijk]);         // Half level liq. water pot. temp.
            const double qth = 0.5 * (qt[ijk-kk] + qt[ijk]);         // Half level specific hum.
            wt[ijk] += buoyancy_no_ql(thh, qth, thvrefh[k]);
        }
    }

    __global__ 
    void calc_buoyancy_g(double* __restrict__ b,  double* __restrict__ th, 
                         double* __restrict__ qt, double* __restrict__ thvref,
                         double* __restrict__ p,  double* __restrict__ exn, 
                         int istart, int jstart, int kstart,
                         int iend,   int jend,   int kcells,
                         int jj, int kk)
    {
        const int i = blockIdx.x*blockDim.x + threadIdx.x + istart; 
        const int j = blockIdx.y*blockDim.y + threadIdx.y + jstart; 
        const int k = blockIdx.z; 

        if (i < iend && j < jend && k < kstart)
        {
            const int ijk   = i + j*jj + k*kk;
            b[ijk] = buoyancy_no_ql(th[ijk], qt[ijk], thvref[k]);
        }
    }

    __global__ 
    void calc_buoyancy_bot_g(double* __restrict__ b,      double* __restrict__ bbot,
                             double* __restrict__ th,     double* __restrict__ thbot, 
                             double* __restrict__ qt,     double* __restrict__ qtbot,
                             double* __restrict__ thvref, double* __restrict__ thvrefh,
                             int kstart, int icells, int jcells,  
                             int jj, int kk)
    {
        const int i = blockIdx.x*blockDim.x + threadIdx.x; 
        const int j = blockIdx.y*blockDim.y + threadIdx.y; 

        if (i < icells && j < jcells)
        {
            const int ij  = i + j*jj;
            const int ijk = i + j*jj + kstart*kk;

            bbot[ij ] = buoyancy_no_ql(thbot[ij], qtbot[ij], thvrefh[kstart]);
            b   [ijk] = buoyancy_no_ql(th[ijk],   qt[ijk],   thvref[kstart]);
        }
    }

    __global__ 
    void calc_buoyancy_flux_bot_g(double* __restrict__ bfluxbot,
                                  double* __restrict__ thbot, double* __restrict__ thfluxbot, 
                                  double* __restrict__ qtbot, double* __restrict__ qtfluxbot,
                                  double* __restrict__ thvrefh, 
                                  int kstart, int icells, int jcells,  
                                  int jj, int kk)
    {
        const int i = blockIdx.x*blockDim.x + threadIdx.x; 
        const int j = blockIdx.y*blockDim.y + threadIdx.y; 

        if (i < icells && j < jcells)
        {
            const int ij  = i + j*jj;
            bfluxbot[ij] = buoyancy_flux_no_ql(thbot[ij], thfluxbot[ij], qtbot[ij], qtfluxbot[ij], thvrefh[kstart]);
        }
    }

    __global__ 
    void calc_N2_g(double* __restrict__ N2, double* __restrict__ th,
                   double* __restrict__ thvref, double* __restrict__ dzi, 
                   int istart, int jstart, int kstart,
                   int iend,   int jend,   int kend,
                   int jj, int kk)
    {
        const int i = blockIdx.x*blockDim.x + threadIdx.x + istart; 
        const int j = blockIdx.y*blockDim.y + threadIdx.y + jstart; 
        const int k = blockIdx.z + kstart; 

        if (i < iend && j < jend && k < kend)
        {
            const int ijk = i + j*jj + k*kk;
            N2[ijk] = grav/thvref[k]*0.5*(th[ijk+kk] - th[ijk-kk])*dzi[k];
        }
    }

    // BvS: no longer used, base state is calculated at the host
    template <int swspatialorder> __global__ 
    void calc_base_state(double* __restrict__ pref,     double* __restrict__ prefh,
                         double* __restrict__ rho,      double* __restrict__ rhoh,
                         double* __restrict__ thv,      double* __restrict__ thvh,
                         double* __restrict__ ex,       double* __restrict__ exh,
                         double* __restrict__ thlmean,  double* __restrict__ qtmean,
                         double* __restrict__ z,        double* __restrict__ dz,
                         double* __restrict__ dzh,
                         double pbot, int kstart, int kend)
    {
        double si, qti;
        double rdcp = Rd/cp;

        double ssurf, qtsurf;
        if (swspatialorder == 2)
        {
            ssurf  = interp2(thlmean[kstart-1], thlmean[kstart]);
            qtsurf = interp2(qtmean[kstart-1],  qtmean[kstart]);
        }
        else if (swspatialorder == 4)
        {
            ssurf  = interp4(thlmean[kstart-2], thlmean[kstart-1], thlmean[kstart], thlmean[kstart+1]);
            qtsurf = interp4(qtmean[kstart-2],  qtmean[kstart-1],  qtmean[kstart],  qtmean[kstart+1]);
        }

        // Calculate surface (half=kstart) values
        exh[kstart]   = exner(pbot);
        thvh[kstart]  = ssurf  * (1. - (1. - Rv/Rd)*qtsurf);
        prefh[kstart] = pbot;
        rhoh[kstart]  = pbot / (Rd * exh[kstart] * thvh[kstart]);

        // First full grid level pressure
        pref[kstart] = pow((pow(pbot,rdcp) - grav * pow(p0,rdcp) * z[kstart] / (cp * thvh[kstart])),(1./rdcp)); 

        for (int k=kstart+1; k<kend+1; k++)
        {
            // 1. Calculate values at full level below zh[k] 
            ex[k-1]  = exner(pref[k-1]);
            thv[k-1] = thlmean[k-1] * (1. - (1. - Rv/Rd)*qtmean[k-1]); 
            rho[k-1] = pref[k-1] / (Rd * ex[k-1] * thv[k-1]);

            // 2. Calculate half level pressure at zh[k] using values at z[k-1]
            prefh[k] = pow((pow(prefh[k-1],rdcp) - grav * pow(p0,rdcp) * dz[k-1] / (cp * thv[k-1])),(1./rdcp));

            // 3. Interpolate conserved variables to zh[k] and calculate virtual temp 
            if (swspatialorder == 2)
            {
                si     = interp2(thlmean[k-1],thlmean[k]);
                qti    = interp2(qtmean[k-1],qtmean[k]);
            }
            else if (swspatialorder == 4)
            {
                si     = interp4(thlmean[k-2],thlmean[k-1],thlmean[k],thlmean[k+1]);
                qti    = interp4(qtmean[k-2],qtmean[k-1],qtmean[k],qtmean[k+1]);
            }

            exh[k]   = exner(prefh[k]);
            thvh[k]  = si * (1. - (1. - Rv/Rd)*qti); 
            rhoh[k]  = prefh[k] / (Rd * exh[k] * thvh[k]); 

            // 4. Calculate full level pressure at z[k]
            pref[k]  = pow((pow(pref[k-1],rdcp) - grav * pow(p0,rdcp) * dzh[k] / (cp * thvh[k])),(1./rdcp)); 
        }

        // Fill bottom and top full level ghost cells 
        if (swspatialorder == 2)
        {
            pref[kstart-1] = 2.*prefh[kstart] - pref[kstart];
            pref[kend]     = 2.*prefh[kend]   - pref[kend-1];
        }
        else if (swspatialorder == 4)
        {
            pref[kstart-1] = (8./3.)*prefh[kstart] - 2.*pref[kstart] + (1./3.)*pref[kstart+1];
            pref[kstart-2] = 8.*prefh[kstart]      - 9.*pref[kstart] + 2.*pref[kstart+1];
            pref[kend]     = (8./3.)*prefh[kend]   - 2.*pref[kend-1] + (1./3.)*pref[kend-2];
            pref[kend+1]   = 8.*prefh[kend]        - 9.*pref[kend-1] + 2.*pref[kend-2];
        }
    } 
    

    // BvS: no longer used, base state is calculated at the host
    template <int swspatialorder> __global__ 
    void calc_hydrostatic_pressure(double* __restrict__ pref,     double* __restrict__ prefh,
                                   double* __restrict__ ex,       double* __restrict__ exh,
                                   double* __restrict__ thlmean,  double* __restrict__ qtmean,
                                   double* __restrict__ z,        double* __restrict__ dz,
                                   double* __restrict__ dzh,
                                   double pbot, int kstart, int kend)
    {
        double ssurf, qtsurf, si, qti, thvh, thv;
        double rdcp = Rd/cp;

        if (swspatialorder == 2)
        {
            ssurf  = interp2(thlmean[kstart-1], thlmean[kstart]);
            qtsurf = interp2(qtmean[kstart-1],  qtmean[kstart]);
        }
        else if (swspatialorder == 4)
        {
            ssurf  = interp4(thlmean[kstart-2], thlmean[kstart-1], thlmean[kstart], thlmean[kstart+1]);
            qtsurf = interp4(qtmean[kstart-2],  qtmean[kstart-1],  qtmean[kstart],  qtmean[kstart+1]);
        }

        // Calculate surface (half=kstart) values
        thvh          = ssurf * (1. - (1. - Rv/Rd)*qtsurf);
        prefh[kstart] = pbot;

        // First full grid level pressure
        pref[kstart] = pow((pow(pbot,rdcp) - grav * pow(p0,rdcp) * z[kstart] / (cp * thvh)),(1./rdcp)); 

        for (int k=kstart+1; k<kend+1; k++)
        {
            // 1. Calculate values at full level below zh[k] 
            ex[k-1]  = exner(pref[k-1]);
            thv      = thlmean[k-1] * (1. - (1. - Rv/Rd)*qtmean[k-1]); 

            // 2. Calculate half level pressure at zh[k] using values at z[k-1]
            prefh[k] = pow((pow(prefh[k-1],rdcp) - grav * pow(p0,rdcp) * dz[k-1] / (cp * thv)),(1./rdcp));

            // 3. Interpolate conserved variables to zh[k] and calculate virtual temp and ql
            if (swspatialorder == 2)
            {
                si     = interp2(thlmean[k-1],thlmean[k]);
                qti    = interp2(qtmean[k-1],qtmean[k]);
            }
            else if (swspatialorder == 4)
            {
                si     = interp4(thlmean[k-2],thlmean[k-1],thlmean[k],thlmean[k+1]);
                qti    = interp4(qtmean[k-2],qtmean[k-1],qtmean[k],qtmean[k+1]);
            }

            exh[k]   = exner(prefh[k]);
            thvh     = si * (1. - (1. - Rv/Rd)*qti); 

            // 4. Calculate full level pressure at z[k]
            pref[k]  = pow((pow(pref[k-1],rdcp) - grav * pow(p0,rdcp) * dzh[k] / (cp * thvh)),(1./rdcp)); 
        }

        // Fill bottom and top full level ghost cells 
        if (swspatialorder == 2)
        {
            pref[kstart-1] = 2.*prefh[kstart] - pref[kstart];
            pref[kend]     = 2.*prefh[kend]   - pref[kend-1];
        }
        else if (swspatialorder == 4)
        {
            pref[kstart-1] = (8./3.)*prefh[kstart] - 2.*pref[kstart] + (1./3.)*pref[kstart+1];
            pref[kstart-2] = 8.*prefh[kstart]      - 9.*pref[kstart] + 2.*pref[kstart+1];
            pref[kend]     = (8./3.)*prefh[kend]   - 2.*pref[kend-1] + (1./3.)*pref[kend-2];
            pref[kend+1]   = 8.*prefh[kend]        - 9.*pref[kend-1] + 2.*pref[kend-2];
        }    
    }      
    
} // end name    space
                 
void Thermo_vapor::prepare_device()
{            
    const int nmemsize = grid->kcells*sizeof(double);
             
    // Allocate fields for Boussinesq and anelastic solver
    cuda_safe_call(cudaMalloc(&thvref_g,  nmemsize));
    cuda_safe_call(cudaMalloc(&thvrefh_g, nmemsize));
    cuda_safe_call(cudaMalloc(&pref_g,    nmemsize));
    cuda_safe_call(cudaMalloc(&prefh_g,   nmemsize));
    cuda_safe_call(cudaMalloc(&exnref_g,  nmemsize));
    cuda_safe_call(cudaMalloc(&exnrefh_g, nmemsize));
             
    // Copy fields to device
    cuda_safe_call(cudaMemcpy(thvref_g,  thvref,  nmemsize, cudaMemcpyHostToDevice));
    cuda_safe_call(cudaMemcpy(thvrefh_g, thvrefh, nmemsize, cudaMemcpyHostToDevice));
    cuda_safe_call(cudaMemcpy(pref_g,    pref,    nmemsize, cudaMemcpyHostToDevice));
    cuda_safe_call(cudaMemcpy(prefh_g,   prefh,   nmemsize, cudaMemcpyHostToDevice));
    cuda_safe_call(cudaMemcpy(exnref_g,  exnref,  nmemsize, cudaMemcpyHostToDevice));
    cuda_safe_call(cudaMemcpy(exnrefh_g, exnrefh, nmemsize, cudaMemcpyHostToDevice));
}            
             
void Thermo_vapor::clear_device()
{            
    cuda_safe_call(cudaFree(thvref_g ));
    cuda_safe_call(cudaFree(thvrefh_g));
    cuda_safe_call(cudaFree(pref_g   ));
    cuda_safe_call(cudaFree(prefh_g  ));
    cuda_safe_call(cudaFree(exnref_g ));
    cuda_safe_call(cudaFree(exnrefh_g));
}            
void Thermo_vapor::forward_device()
{
    // Copy fields to device
    const int nmemsize = grid->kcells*sizeof(double);
    cuda_safe_call(cudaMemcpy(pref_g,    pref,    nmemsize, cudaMemcpyHostToDevice));
    cuda_safe_call(cudaMemcpy(prefh_g,   prefh,   nmemsize, cudaMemcpyHostToDevice));
    cuda_safe_call(cudaMemcpy(exnref_g,  exnref,  nmemsize, cudaMemcpyHostToDevice));
    cuda_safe_call(cudaMemcpy(exnrefh_g, exnrefh, nmemsize, cudaMemcpyHostToDevice));
}            
void Thermo_vapor::backward_device()
{
    const int nmemsize = grid->kcells*sizeof(double);
    cudaMemcpy(pref_g,    pref,    nmemsize, cudaMemcpyHostToDevice);
    cudaMemcpy(prefh_g,   prefh,   nmemsize, cudaMemcpyHostToDevice);
    cudaMemcpy(exnref_g,  exnref,  nmemsize, cudaMemcpyHostToDevice);
    cudaMemcpy(exnrefh_g, exnrefh, nmemsize, cudaMemcpyHostToDevice);
}
             
#ifdef USECUDA
void Thermo_vapor::exec()
{            
    const int blocki = grid->ithread_block;
    const int blockj = grid->jthread_block;
    const int gridi  = grid->imax/blocki + (grid->imax%blocki > 0);
    const int gridj  = grid->jmax/blockj + (grid->jmax%blockj > 0);
             
    dim3 gridGPU (gridi, gridj, grid->kmax);
    dim3 blockGPU(blocki, blockj, 1);
             
    const int offs = grid->memoffset;
             
    // Re-calculate hydrostatic pressure and exner
    if (swupdatebasestate)
    {        
        double * restrict tmp2 = fields->atmp["tmp2"]->data_g;
        if(grid->swspatialorder == "2")
        {
          calc_hydrostatic_pressure<2><<<1, 1>>>(pref_g, prefh_g, exnref_g, exnrefh_g, 
                                                              fields->sp["thl"]->datamean_g, fields->sp["qt"]->datamean_g, 
                                                              grid->z_g, grid->dz_g, grid->dzh_g, pbot, grid->kstart, grid->kend);
        }
        else if(grid->swspatialorder == "4")
        {
          calc_hydrostatic_pressure<4><<<1, 1>>>(pref_g, prefh_g, exnref_g, exnrefh_g, 
                                                              fields->sp["thl"]->datamean_g, fields->sp["qt"]->datamean_g, 
                                                              grid->z_g, grid->dz_g, grid->dzh_g, pbot, grid->kstart, grid->kend);
        }
        cuda_check_error();
             
        /* BvS: Calculating hydrostatic pressure on GPU is extremely slow. As temporary solution, copy back mean profiles to host,
        //      calculate pressure there and copy back the required profiles. 
        cudaMemcpy(fields->sp["thl"]->datamean, fields->sp["thl"]->datamean_g, grid->kcells*sizeof(double), cudaMemcpyDeviceToHost);
        cudaMemcpy(fields->sp["qt"]->datamean,  fields->sp["qt"]->datamean_g,  grid->kcells*sizeof(double), cudaMemcpyDeviceToHost);
             
        int kcells = grid->kcells; 
        double *tmp2 = fields->atmp["tmp2"]->data;
        calc_base_state(pref, prefh, &tmp2[0*kcells], &tmp2[1*kcells], &tmp2[2*kcells], &tmp2[3*kcells], exnref, exnrefh, 
                fields->sp["thl"]->datamean, fields->sp["qt"]->datamean);
             
        // Only half level pressure and exner needed for BuoyancyTend()
        cudaMemcpy(prefh_g,   prefh,   grid->kcells*sizeof(double), cudaMemcpyHostToDevice);
        cudaMemcpy(exnrefh_g, exnrefh, grid->kcells*sizeof(double), cudaMemcpyHostToDevice);
        */
    }

    if (grid->swspatialorder== "2")
    {
        calc_buoyancy_tend_2nd_g<<<gridGPU, blockGPU>>>(
            &fields->wt->data_g[offs], &fields->sp["thl"]->data_g[offs], 
            &fields->sp["qt"]->data_g[offs], thvrefh_g, exnrefh_g, prefh_g,  
            grid->istart,  grid->jstart, grid->kstart+1,
            grid->iend,    grid->jend,   grid->kend,
            grid->icellsp, grid->ijcellsp);
        cuda_check_error();
    }
    else if (grid->swspatialorder == "4")
    {
        master->print_message("4th order thermo_moist not (yet) implemented\n");  
        throw 1;
    }
}
#endif

#ifdef USECUDA
void Thermo_vapor::get_thermo_field(Field3d *fld, Field3d *tmp, std::string name, bool cyclic )
{
    const int blocki = grid->ithread_block;
    const int blockj = grid->jthread_block;
    const int gridi  = grid->imax/blocki + (grid->imax%blocki > 0);
    const int gridj  = grid->jmax/blockj + (grid->jmax%blockj > 0);

    dim3 gridGPU (gridi, gridj, grid->kcells);
    dim3 blockGPU(blocki, blockj, 1);

    dim3 gridGPU2 (gridi, gridj, grid->kmax);
    dim3 blockGPU2(blocki, blockj, 1);

    const int offs = grid->memoffset;

    // BvS: getthermofield() is called from subgrid-model, before thermo(), so re-calculate the hydrostatic pressure
    if (swupdatebasestate && (name == "b" || name == "ql"))
    {
        double * restrict tmp2 = fields->atmp["tmp2"]->data_g;
        if(grid->swspatialorder == "2")
          calc_hydrostatic_pressure<2><<<1, 1>>>(pref_g, prefh_g, exnref_g, exnrefh_g, 
                                                              fields->sp["thl"]->datamean_g, fields->sp["qt"]->datamean_g, 
                                                              grid->z_g, grid->dz_g, grid->dzh_g, pbot, grid->kstart, grid->kend);
        else if(grid->swspatialorder == "4")
          calc_hydrostatic_pressure<4><<<1, 1>>>(pref_g, prefh_g, exnref_g, exnrefh_g, 
                                                              fields->sp["thl"]->datamean_g, fields->sp["qt"]->datamean_g, 
                                                              grid->z_g, grid->dz_g, grid->dzh_g, pbot, grid->kstart, grid->kend);
        cuda_check_error();

        /* BvS: Calculating hydrostatic pressure on GPU is extremely slow. As temporary solution, copy back mean profiles to host,
        //      calculate pressure there and copy back the required profiles. 
        cudaMemcpy(fields->sp["thl"]->datamean, fields->sp["thl"]->datamean_g, grid->kcells*sizeof(double), cudaMemcpyDeviceToHost);
        cudaMemcpy(fields->sp["qt"]->datamean,  fields->sp["qt"]->datamean_g,  grid->kcells*sizeof(double), cudaMemcpyDeviceToHost);
        
        int kcells = grid->kcells; 
        double *tmp2 = fields->atmp["tmp2"]->data;
        calc_base_state(pref, prefh, &tmp2[0*kcells], &tmp2[1*kcells], &tmp2[2*kcells], &tmp2[3*kcells], exnref, exnrefh, 
                fields->sp["thl"]->datamean, fields->sp["qt"]->datamean);

        // Only full level pressure and exner needed
        cudaMemcpy(pref_g,   pref,   grid->kcells*sizeof(double), cudaMemcpyHostToDevice);
        cudaMemcpy(exnref_g, exnref, grid->kcells*sizeof(double), cudaMemcpyHostToDevice);
        */
    }

    if (name == "b")
    {
        calc_buoyancy_g<<<gridGPU, blockGPU>>>(
            &fld->data_g[offs], &fields->sp["thl"]->data_g[offs], &fields->sp["qt"]->data_g[offs],
            thvref_g, pref_g, exnref_g,
            grid->istart,  grid->jstart, grid->kstart, 
            grid->iend, grid->jend, grid->kcells,
            grid->icellsp, grid->ijcellsp);
        cuda_check_error();
    }
    else if (name == "N2")
    {
        calc_N2_g<<<gridGPU2, blockGPU2>>>(
            &fld->data_g[offs], &fields->sp["thl"]->data_g[offs], thvref_g, grid->dzi_g, 
            grid->istart,  grid->jstart, grid->kstart, 
            grid->iend,    grid->jend,   grid->kend,
            grid->icellsp, grid->ijcellsp);
        cuda_check_error();
    }
    else
    {
        master->print_error("get_thermo_field \"%s\" not supported\n",name.c_str());
        throw 1;
    }

    if (cyclic)
        grid->boundary_cyclic_g(&fld->data_g[offs]);
}
#endif

#ifdef USECUDA
void Thermo_vapor::get_buoyancy_fluxbot(Field3d *bfield)
{
    const int blocki = grid->ithread_block;
    const int blockj = grid->jthread_block;
    const int gridi  = grid->icells/blocki + (grid->icells%blocki > 0);
    const int gridj  = grid->jcells/blockj + (grid->jcells%blockj > 0);

    dim3 gridGPU (gridi, gridj, 1);
    dim3 blockGPU(blocki, blockj, 1);

    const int offs = grid->memoffset;

    calc_buoyancy_flux_bot_g<<<gridGPU, blockGPU>>>(
        &bfield->datafluxbot_g[offs], 
        &fields->sp["thl"] ->databot_g[offs], &fields->sp["thl"] ->datafluxbot_g[offs], 
        &fields->sp["qt"]->databot_g[offs], &fields->sp["qt"]->datafluxbot_g[offs], 
        thvrefh_g, grid->kstart, grid->icells, grid->jcells, 
        grid->icellsp, grid->ijcellsp);
    cuda_check_error();
}
#endif

#ifdef USECUDA
void Thermo_vapor::get_buoyancy_surf(Field3d *bfield)
{
    const int blocki = grid->ithread_block;
    const int blockj = grid->jthread_block;
    const int gridi  = grid->icells/blocki + (grid->icells%blocki > 0);
    const int gridj  = grid->jcells/blockj + (grid->jcells%blockj > 0);

    dim3 gridGPU (gridi, gridj, 1);
    dim3 blockGPU(blocki, blockj, 1);

    const int offs = grid->memoffset;

    calc_buoyancy_bot_g<<<gridGPU, blockGPU>>>(
        &bfield->data_g[offs], &bfield->databot_g[offs], 
        &fields->sp["thl"] ->data_g[offs], &fields->sp["thl"] ->databot_g[offs],
        &fields->sp["qt"]->data_g[offs], &fields->sp["qt"]->databot_g[offs],
        thvref_g, thvrefh_g, grid->kstart, grid->icells, grid->jcells, 
        grid->icellsp, grid->ijcellsp);
    cuda_check_error();

    calc_buoyancy_flux_bot_g<<<gridGPU, blockGPU>>>(
        &bfield->datafluxbot_g[offs], 
        &fields->sp["thl"] ->databot_g[offs], &fields->sp["thl"] ->datafluxbot_g[offs], 
        &fields->sp["qt"]->databot_g[offs], &fields->sp["qt"]->datafluxbot_g[offs], 
        thvrefh_g, grid->kstart, grid->icells, grid->jcells, 
        grid->icellsp, grid->ijcellsp);
    cuda_check_error();
}
#endif
