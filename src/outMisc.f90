module outMisc_mod
   !
   ! This module contains several subroutines that can compute and store
   ! various informations: helicity, heat transfer.
   !

   use parallel_mod
   use precision_mod
   use communications, only: gather_from_Rloc
   use truncation, only: l_max, n_r_max, lm_max, nlat_padded, n_theta_max
   use radial_data, only: n_r_icb, n_r_cmb, nRstart, nRstop
   use radial_functions, only: r_icb, rscheme_oc, kappa,         &
       &                       r_cmb,temp0, r, rho0, dLtemp0,    &
       &                       dLalpha0, beta, orho1, alpha0,    &
       &                       otemp1, ogrun, rscheme_oc
   use physical_parameters, only: ViscHeatFac, ThExpNb, opr, stef
   use num_param, only: lScale, eScale
   use blocking, only: llm, ulm, lo_map
   use mean_sd, only: mean_sd_type
   use horizontal_data, only: gauss, theta_ord, n_theta_cal2ord
   use logic, only: l_save_out, l_anelastic_liquid, l_heat, l_hel, &
       &            l_temperature_diff, l_chemical_conv, l_phase_field
   use output_data, only: tag
   use constants, only: pi, vol_oc, osq4pi, sq4pi, one, two, four, half, zero
   use start_fields, only: topcond, botcond, deltacond, topxicond, botxicond, &
       &                   deltaxicond
   use useful, only: cc2real, round_off
   use integration, only: rInt_R
   use sht, only: axi_to_spat

   implicit none

   private

   type(mean_sd_type) :: TMeanR, SMeanR, PMeanR, XiMeanR, RhoMeanR, PhiMeanR
   integer :: n_heat_file, n_helicity_file, n_calls, n_phase_file
   integer :: n_rmelt_file
   character(len=72) :: heat_file, helicity_file, phase_file, rmelt_file
   real(cp) :: TPhiOld, Tphi

   public :: outHelicity, outHeat, initialize_outMisc_mod, finalize_outMisc_mod, &
   &         outPhase

contains

   subroutine initialize_outMisc_mod
      !
      ! This subroutine handles the opening the output diagnostic files that
      ! have to do with heat transfer or helicity.
      !

      if (l_heat .or. l_chemical_conv) then
         call TMeanR%initialize(1,n_r_max)
         call SMeanR%initialize(1,n_r_max)
         call PMeanR%initialize(1,n_r_max)
         call XiMeanR%initialize(1,n_r_max)
         call RhoMeanR%initialize(1,n_r_max)
      endif
      if ( l_phase_field ) call PhiMeanR%initialize(1,n_r_max)
      n_calls = 0

      TPhiOld = 0.0_cp
      TPhi = 0.0_cp

      helicity_file='helicity.'//tag
      heat_file    ='heat.'//tag
      if ( rank == 0 .and. (.not. l_save_out) ) then
         if ( l_hel ) then
            open(newunit=n_helicity_file, file=helicity_file, status='new')
         end if
         if ( l_heat .or. l_chemical_conv ) then
            open(newunit=n_heat_file, file=heat_file, status='new')
         end if
      end if

      if ( l_phase_field ) then
         phase_file='phase.'//tag
         rmelt_file='rmelt.'//tag
         if ( rank == 0 .and. (.not. l_save_out) ) then
            open(newunit=n_phase_file, file=phase_file, status='new')
            open(newunit=n_rmelt_file, file=rmelt_file, status='new', form='unformatted')
         end if
      end if

   end subroutine initialize_outMisc_mod
!---------------------------------------------------------------------------
   subroutine finalize_outMisc_mod
      !
      ! This subroutine handles the closing of the time series of
      ! heat.TAG, hel.TAG and phase.TAG
      !

      if ( l_heat .or. l_chemical_conv ) then
         call TMeanR%finalize()
         call SMeanR%finalize()
         call PMeanR%finalize()
         call XiMeanR%finalize()
         call RhoMeanR%finalize()
      end if
      if ( l_phase_field ) call PhiMeanR%finalize()

      if ( rank == 0 .and. (.not. l_save_out) ) then
         if ( l_hel ) close(n_helicity_file)
         if ( l_heat .or. l_chemical_conv ) close(n_heat_file)
         if ( l_phase_field ) then
            close(n_phase_file)
            close(n_rmelt_file)
         end if
      end if

   end subroutine finalize_outMisc_mod
!---------------------------------------------------------------------------
   subroutine outHelicity(timeScaled,HelASr,Hel2ASr,HelnaASr,Helna2ASr,HelEAASr)
      !
      ! This subroutine is used to store informations about kinetic
      ! helicity
      !

      !-- Input of variables:
      real(cp), intent(in) :: timeScaled
      real(cp), intent(in) :: HelASr(2,nRstart:nRstop)
      real(cp), intent(in) :: Hel2ASr(2,nRstart:nRstop)
      real(cp), intent(in) :: HelnaASr(2,nRstart:nRstop)
      real(cp), intent(in) :: Helna2ASr(2,nRstart:nRstop)
      real(cp), intent(in) :: HelEAASr(nRstart:nRstop)

      !-- Local stuff:
      real(cp) :: HelNr_global(n_r_max), HelSr_global(n_r_max)
      real(cp) :: HelnaNr_global(n_r_max), HelnaSr_global(n_r_max)
      real(cp) :: Helna2Nr_global(n_r_max), Helna2Sr_global(n_r_max)
      real(cp) :: Hel2Nr_global(n_r_max), Hel2Sr_global(n_r_max)
      real(cp) :: HelEAr_global(n_r_max)
      real(cp) :: HelN,HelS,HelnaN,HelnaS,HelnaRMSN,HelnaRMSS
      real(cp) :: HelRMSN,HelRMSS,HelEA,HelRMS,HelnaRMS

      ! Now we have to gather the results on rank 0 for
      ! the arrays: Hel2Nr,Helna2Nr,HelEAr,HelNr,HelnaNr
      ! Hel2Sr,Helna2Sr,HelSr,HelnaSr

      call gather_from_Rloc(Hel2Asr(1,:), Hel2Nr_global, 0)
      call gather_from_Rloc(Helna2ASr(1,:), Helna2Nr_global, 0)
      call gather_from_Rloc(HelEAASr, HelEAr_global, 0)
      call gather_from_Rloc(HelASr(1,:), HelNr_global, 0)
      call gather_from_Rloc(HelnaASr(1,:), HelnaNr_global, 0)
      call gather_from_Rloc(HelASr(2,:), HelSr_global, 0)
      call gather_from_Rloc(Helna2ASr(2,:), Helna2Sr_global, 0)
      call gather_from_Rloc(Hel2ASr(2,:), Hel2Sr_global, 0)
      call gather_from_Rloc(HelnaASr(2,:), HelnaSr_global, 0)

      if ( rank == 0 ) then
         !------ Integration over r without the boundaries and normalization:
         HelN  =rInt_R(HelNr_global*r*r,r,rscheme_oc)
         HelS  =rInt_R(HelSr_global*r*r,r,rscheme_oc)
         HelnaN=rInt_R(HelnaNr_global*r*r,r,rscheme_oc)
         HelnaS=rInt_R(HelnaSr_global*r*r,r,rscheme_oc)
         HelEA =rInt_R(HelEAr_global*r*r,r,rscheme_oc)
         HelRMSN=rInt_R(Hel2Nr_global*r*r,r,rscheme_oc)
         HelRMSS=rInt_R(Hel2Sr_global*r*r,r,rscheme_oc)
         HelnaRMSN=rInt_R(Helna2Nr_global*r*r,r,rscheme_oc)
         HelnaRMSS=rInt_R(Helna2Sr_global*r*r,r,rscheme_oc)

         HelN  =two*pi*HelN/(vol_oc/2) ! Note integrated over half spheres only !
         HelS  =two*pi*HelS/(vol_oc/2) ! Factor 2*pi is from phi integration
         HelnaN=two*pi*HelnaN/(vol_oc/2) ! Note integrated over half spheres only !
         HelnaS=two*pi*HelnaS/(vol_oc/2) ! Factor 2*pi is from phi integration
         HelEA =two*pi*HelEA/vol_oc
         HelRMSN=sqrt(two*pi*HelRMSN/(vol_oc/2))
         HelRMSS=sqrt(two*pi*HelRMSS/(vol_oc/2))
         HelnaRMSN=sqrt(two*pi*HelnaRMSN/(vol_oc/2))
         HelnaRMSS=sqrt(two*pi*HelnaRMSS/(vol_oc/2))
         HelRMS=HelRMSN+HelRMSS
         HelnaRMS=HelnaRMSN+HelnaRMSS

         if ( HelnaRMS /= 0 ) then
            HelnaN =HelnaN/HelnaRMSN
            HelnaS =HelnaS/HelnaRMSS
         else
            HelnaN =0.0_cp
            HelnaS =0.0_cp
         end if
         if ( HelRMS /= 0 ) then
            HelN =HelN/HelRMSN
            HelS =HelS/HelRMSS
            HelEA=HelEA/HelRMS
         else
            HelN =0.0_cp
            HelS =0.0_cp
            HelEA=0.0_cp
         end if

         if ( l_save_out ) then
            open(newunit=n_helicity_file, file=helicity_file,   &
            &    status='unknown', position='append')
         end if

         write(n_helicity_file,'(1P,ES20.12,8ES16.8)')   &
         &     timeScaled,HelN, HelS, HelRMSN, HelRMSS,  &
         &     HelnaN, HelnaS, HelnaRMSN, HelnaRMSS

         if ( l_save_out ) close(n_helicity_file)

      end if

   end subroutine outHelicity
!---------------------------------------------------------------------------
   subroutine outHeat(time,timePassed,timeNorm,l_stop_time,s,ds,p,dp,xi,dxi)
      !
      ! This subroutine is used to store informations about heat transfer
      ! (i.e. Nusselt number, temperature, entropy, ...)
      !

      !-- Input of variables:
      real(cp),    intent(in) :: time
      real(cp),    intent(in) :: timePassed
      real(cp),    intent(in) :: timeNorm
      logical,     intent(in) :: l_stop_time

      !-- Input of scalar fields:
      complex(cp), intent(in) :: s(llm:ulm,n_r_max)
      complex(cp), intent(in) :: ds(llm:ulm,n_r_max)
      complex(cp), intent(in) :: p(llm:ulm,n_r_max)
      complex(cp), intent(in) :: dp(llm:ulm,n_r_max)
      complex(cp), intent(in) :: xi(llm:ulm,n_r_max)
      complex(cp), intent(in) :: dxi(llm:ulm,n_r_max)

      !-- Local stuff:
      real(cp) :: tmp(n_r_max)
      real(cp) :: topnuss,botnuss,deltanuss
      real(cp) :: topsherwood,botsherwood,deltasherwood
      real(cp) :: toptemp,bottemp
      real(cp) :: topxi,botxi
      real(cp) :: toppres,botpres,mass
      real(cp) :: topentropy, botentropy
      real(cp) :: topflux,botflux
      character(len=76) :: filename
      integer :: n_r, filehandle

      if ( rank == 0 ) then
         n_calls = n_calls + 1
         if ( l_anelastic_liquid ) then
            if ( l_heat ) then
               call TMeanR%compute(osq4pi*real(s(1,:)),n_calls,timePassed,timeNorm)
               tmp(:)   = otemp1(:)*TMeanR%mean(:)-ViscHeatFac*ThExpNb* &
               &          alpha0(:)*orho1(:)*PmeanR%mean(:)
               call SMeanR%compute(tmp(:),n_calls,timePassed,timeNorm)
            endif
            if ( l_chemical_conv ) then
               call XiMeanR%compute(osq4pi*real(xi(1,:)),n_calls,timePassed,timeNorm)
            endif
            call PMeanR%compute(osq4pi*real(p(1,:)),n_calls,timePassed,timeNorm)
            tmp(:) = osq4pi*ThExpNb*alpha0(:)*( -rho0(:)*    &
               &     real(s(1,:))+ViscHeatFac*(ThExpNb*      &
               &     alpha0(:)*temp0(:)+ogrun(:))*           &
               &     real(p(1,:)) )
            call RhoMeanR%compute(tmp(:),n_calls,timePassed,timeNorm)
         else
            if ( l_heat ) then
               call SMeanR%compute(osq4pi*real(s(1,:)),n_calls,timePassed,timeNorm)
               tmp(:) = temp0(:)*SMeanR%mean(:)+ViscHeatFac*ThExpNb* &
               &        alpha0(:)*temp0(:)*orho1(:)*PMeanR%mean(:)
               call TMeanR%compute(tmp(:), n_calls, timePassed, timeNorm)
            endif
            if ( l_chemical_conv ) then
               call XiMeanR%compute(osq4pi*real(xi(1,:)),n_calls,timePassed,timeNorm)
            endif
            call PMeanR%compute(osq4pi*real(p(1,:)),n_calls,timePassed,timeNorm)
            tmp(:) = osq4pi*ThExpNb*alpha0(:)*( -rho0(:)* &
               &     temp0(:)*real(s(1,:))+ViscHeatFac*   &
               &     ogrun(:)*real(p(1,:)) )
            call RhoMeanR%compute(tmp(:),n_calls,timePassed,timeNorm)
         end if

         !-- Evaluate nusselt numbers (boundary heat flux density):
         toppres=osq4pi*real(p(1,n_r_cmb))
         botpres=osq4pi*real(p(1,n_r_icb))
         if ( topcond /= 0.0_cp ) then

            if ( l_anelastic_liquid ) then

               bottemp=osq4pi*real(s(1,n_r_icb))
               toptemp=osq4pi*real(s(1,n_r_cmb))

               botentropy=otemp1(n_r_icb)*bottemp-ViscHeatFac*ThExpNb*   &
               &          orho1(n_r_icb)*alpha0(n_r_icb)*botpres
               topentropy=otemp1(n_r_cmb)*toptemp-ViscHeatFac*ThExpNb*   &
               &          orho1(n_r_cmb)*alpha0(n_r_cmb)*toppres

               if ( l_temperature_diff ) then

                  botnuss=-osq4pi/botcond*real(ds(1,n_r_icb))/lScale
                  topnuss=-osq4pi/topcond*real(ds(1,n_r_cmb))/lScale
                  botflux=-rho0(n_r_max)*real(ds(1,n_r_max))*osq4pi &
                  &        *r_icb**2*four*pi*kappa(n_r_max)
                  topflux=-rho0(1)*real(ds(1,1))*osq4pi &
                  &        *r_cmb**2*four*pi*kappa(1)

                  deltanuss = deltacond/(bottemp-toptemp)

               else

                  botnuss=-osq4pi/botcond*(otemp1(n_r_icb)*( -dLtemp0(n_r_icb)* &
                  &        real(s(1,n_r_icb)) + real(ds(1,n_r_icb))) -          &
                  &        ViscHeatFac*ThExpNb*alpha0(n_r_icb)*orho1(n_r_icb)*( &
                  &         ( dLalpha0(n_r_icb)-beta(n_r_icb) )*                &
                  &        real(p(1,n_r_icb)) + real(dp(1,n_r_icb)) ) ) / lScale
                  topnuss=-osq4pi/topcond*(otemp1(n_r_cmb)*( -dLtemp0(n_r_cmb)* &
                  &        real(s(1,n_r_cmb)) + real(ds(1,n_r_cmb))) -          &
                  &        ViscHeatFac*ThExpNb*alpha0(n_r_cmb)*orho1(n_r_cmb)*( &
                  &         ( dLalpha0(n_r_cmb)-beta(n_r_cmb) )*                &
                  &        real(p(1,n_r_cmb)) + real(dp(1,n_r_cmb)) ) ) / lScale

                  botflux=four*pi*r_icb**2*kappa(n_r_icb)*rho0(n_r_icb) *      &
                  &       botnuss*botcond*lScale*temp0(n_r_icb)
                  topflux=four*pi*r_cmb**2*kappa(n_r_cmb)*rho0(n_r_cmb) *      &
                  &       topnuss*topcond*lScale*temp0(n_r_cmb)

                  deltanuss = deltacond/(botentropy-topentropy)

               end if

            else ! s corresponds to entropy

               botentropy=osq4pi*real(s(1,n_r_icb))
               topentropy=osq4pi*real(s(1,n_r_cmb))

               bottemp   =temp0(n_r_icb)*botentropy+ViscHeatFac*ThExpNb*   &
               &          orho1(n_r_icb)*temp0(n_r_icb)*alpha0(n_r_icb)*   &
               &          botpres
               toptemp   =temp0(n_r_cmb)*topentropy+ViscHeatFac*ThExpNb*   &
               &          orho1(n_r_cmb)*temp0(n_r_cmb)*alpha0(n_r_cmb)*   &
               &          toppres

               if ( l_temperature_diff ) then

                  botnuss=-osq4pi/botcond*temp0(n_r_icb)*( dLtemp0(n_r_icb)*   &
                  &        real(s(1,n_r_icb)) + real(ds(1,n_r_icb)) +          &
                  &        ViscHeatFac*ThExpNb*alpha0(n_r_icb)*orho1(n_r_icb)*(&
                  &     ( dLalpha0(n_r_icb)+dLtemp0(n_r_icb)-beta(n_r_icb) )*  &
                  &        real(p(1,n_r_icb)) + real(dp(1,n_r_icb)) ) ) / lScale
                  topnuss=-osq4pi/topcond*temp0(n_r_cmb)*( dLtemp0(n_r_cmb)*   &
                  &        real(s(1,n_r_cmb)) + real(ds(1,n_r_cmb)) +          &
                  &        ViscHeatFac*ThExpNb*alpha0(n_r_cmb)*orho1(n_r_cmb)*(&
                  &     ( dLalpha0(n_r_cmb)+dLtemp0(n_r_cmb)-beta(n_r_cmb) )*  &
                  &        real(p(1,n_r_cmb)) + real(dp(1,n_r_cmb)) ) ) / lScale

                  botflux=four*pi*r_icb**2*kappa(n_r_icb)*rho0(n_r_icb) *      &
                  &       botnuss*botcond*lScale
                  topflux=four*pi*r_cmb**2*kappa(n_r_cmb)*rho0(n_r_cmb) *      &
                  &       topnuss*topcond*lScale

                  deltanuss = deltacond/(bottemp-toptemp)

               else

                  botnuss=-osq4pi/botcond*real(ds(1,n_r_icb))/lScale
                  topnuss=-osq4pi/topcond*real(ds(1,n_r_cmb))/lScale
                  botflux=-rho0(n_r_max)*temp0(n_r_max)*real(ds(1,n_r_max))* &
                  &        r_icb**2*sq4pi*kappa(n_r_max)/lScale
                  topflux=-rho0(1)*temp0(1)*real(ds(1,1))/lScale*r_cmb**2* &
                  &        sq4pi*kappa(1)
                  if ( botentropy /= topentropy ) then
                     deltanuss = deltacond/(botentropy-topentropy)
                  else
                     deltanuss = one
                  end if

               end if

            end if
         else
            botnuss   =one
            topnuss   =one
            botflux   =0.0_cp
            topflux   =0.0_cp
            bottemp   =0.0_cp
            toptemp   =0.0_cp
            botentropy=0.0_cp
            topentropy=0.0_cp
            deltanuss =one
         end if

         if ( l_chemical_conv ) then
            if ( topxicond/=0.0_cp ) then
               topxi=osq4pi*real(xi(1,n_r_cmb))
               botxi=osq4pi*real(xi(1,n_r_icb))
               botsherwood=-osq4pi/botxicond*real(dxi(1,n_r_icb))/lScale
               topsherwood=-osq4pi/topxicond*real(dxi(1,n_r_cmb))/lScale
               deltasherwood = deltaxicond/(botxi-topxi)
            else
               topxi=0.0_cp
               botxi=0.0_cp
               botsherwood=one
               topsherwood=one
               deltasherwood=one
            end if
         else
            topxi=0.0_cp
            botxi=0.0_cp
            botsherwood=one
            topsherwood=one
            deltasherwood=one
         end if

         tmp(:)=tmp(:)*r(:)*r(:)
         mass=four*pi*rInt_R(tmp,r,rscheme_oc)

         if ( l_save_out ) then
            open(newunit=n_heat_file, file=heat_file, status='unknown', &
            &    position='append')
         end if

         !-- avoid too small number in output
         if ( abs(toppres) <= 1e-11_cp ) toppres=0.0_cp

         if ( abs(mass) <= 1e-11_cp ) mass=0.0_cp

         write(n_heat_file,'(1P,ES20.12,16ES16.8)')          &
         &     time, botnuss, topnuss, deltanuss,            &
         &     bottemp, toptemp, botentropy, topentropy,     &
         &     botflux, topflux, toppres, mass, topsherwood, &
         &     botsherwood, deltasherwood, botxi, topxi

         if ( l_save_out ) close(n_heat_file)

         if ( l_stop_time ) then
            call SMeanR%finalize_SD(timeNorm)
            call TMeanR%finalize_SD(timeNorm)
            call PMeanR%finalize_SD(timeNorm)
            call XiMeanR%finalize_SD(timeNorm)
            call RhoMeanR%finalize_SD(timeNorm)

            filename='heatR.'//tag
            open(newunit=filehandle, file=filename, status='unknown')
            do n_r=1,n_r_max
               write(filehandle, '(ES20.10,5ES15.7,5ES13.5)' )                &
               &      r(n_r),round_off(SMeanR%mean(n_r),maxval(SMeanR%mean)), &
               &      round_off(TMeanR%mean(n_r),maxval(TMeanR%mean)),        &
               &      round_off(PMeanR%mean(n_r),maxval(PMeanR%mean)),        &
               &      round_off(RhoMeanR%mean(n_r),maxval(RhoMeanR%mean)),    &
               &      round_off(XiMeanR%mean(n_r),maxval(XiMeanR%mean)),      &
               &      round_off(SMeanR%SD(n_r),maxval(SMeanR%SD)),            &
               &      round_off(TMeanR%SD(n_r),maxval(TMeanR%SD)),            &
               &      round_off(PMeanR%SD(n_r),maxval(PMeanR%SD)),            &
               &      round_off(RhoMeanR%SD(n_r),maxval(RhoMeanR%SD)),        &
               &      round_off(XiMeanR%SD(n_r),maxval(XiMeanR%SD))
            end do

            close(filehandle)
         end if

      end if ! rank == 0

   end subroutine outHeat
!---------------------------------------------------------------------------
   subroutine outPhase(time, timePassed, timeNorm, l_stop_time, nLogs, s, ds, &
              &        phi, ekinSr, ekinLr, volSr)
      !
      ! This subroutine handles the writing of time series related with phase
      ! field: phase.TAG
      !

      !-- Input variables
      real(cp),    intent(in) :: time                   ! Time
      real(cp),    intent(in) :: timePassed             ! Time passed since last call
      real(cp),    intent(in) :: timeNorm
      logical,     intent(in) :: l_stop_time            ! Last iteration
      integer,     intent(in) :: nLogs                  ! Number of log outputs
      complex(cp), intent(in) :: s(llm:ulm,n_r_max)     ! Entropy/Temperature
      complex(cp), intent(in) :: ds(llm:ulm,n_r_max)    ! Radial der. of Entropy/Temperature
      complex(cp), intent(in) :: phi(llm:ulm,n_r_max)   ! Phase field
      real(cp),    intent(in) :: ekinSr(nRstart:nRstop) ! Kinetic energy in solidus
      real(cp),    intent(in) :: ekinLr(nRstart:nRstop) ! Kinetic energy in liquidus
      real(cp),    intent(in) :: volSr(nRstart:nRstop)  ! Volume of the solid phase

      !-- Local variables
      character(len=72) :: filename
      integer :: lm00, n_r, n_r_phase, filehandle, l, m, lm, n_t, n_t_ord
      complex(cp) :: phi_axi(l_max+1,n_r_max), phi_axi_loc(l_max+1,n_r_max)
      real(cp) :: phi_axi_g(n_r_max,nlat_padded), rmelt(n_theta_max)
      real(cp) :: ekinSr_global(n_r_max), ekinLr_global(n_r_max), volSr_global(n_r_max)
      real(cp) :: tmp(n_r_max), phi_theta(nlat_padded)
      real(cp) :: ekinL, ekinS, fcmb, ficb, dtTPhi, slope, intersect, volS
      real(cp) :: rphase, tphase

      !-- MPI gather on rank=0
      call gather_from_Rloc(ekinSr,ekinSr_global,0)
      call gather_from_Rloc(ekinLr,ekinLr_global,0)
      call gather_from_Rloc(volSr,volSr_global,0)

      !-- Re-arange m=0 modes and communicate them to rank=0
      do n_r=1,n_r_max
         phi_axi_loc(:,n_r)=zero
         do lm=llm,ulm
            l = lo_map%lm2l(lm)
            m = lo_map%lm2m(lm)
            if ( m == 0 ) phi_axi_loc(l+1,n_r)=phi(lm,n_r)
         end do

#ifdef WITH_MPI
         call MPI_Reduce(phi_axi_loc(:,n_r), phi_axi(:,n_r), l_max+1, &
              &          MPI_DEF_COMPLEX, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
#else
         phi_axi(:,n_r)=phi_axi_loc(:,n_r)
#endif
      end do

      if ( rank == 0 ) then

         !-- Get axisymmetric phase field on the grid
         do n_r=1,n_r_max
            call axi_to_spat(phi_axi(:,n_r), phi_theta)
            phi_axi_g(n_r,:)=phi_theta(:)
         end do

         !-- Now get the melting points for each colatitude and compute a linear
         !-- interpolation to get rmelt(theta)
         do n_t=1,n_theta_max
            n_r_phase=2
            do n_r=2,n_r_max
               if ( phi_axi_g(n_r,n_t) < half .and. phi_axi_g(n_r-1,n_t) > half ) then
                  n_r_phase=n_r
                  exit
               end if
            end do
            n_t_ord=n_theta_cal2ord(n_t)
            if ( n_r_phase /= 2 ) then
               slope=(phi_axi_g(n_r_phase,n_t)-phi_axi_g(n_r_phase-1,n_t)) / &
               &     (r(n_r_phase)-r(n_r_phase-1))
               intersect=phi_axi_g(n_r_phase,n_t)-slope*r(n_r_phase)
               rmelt(n_t_ord)=(half-intersect)/slope
            else
               rmelt(n_t_ord)=r_cmb
            end if
         end do

         !-- Now save the melting line into a binary file
         if ( l_save_out ) then
            open(newunit=n_rmelt_file, file=rmelt_file, status='unknown', &
            &    position='append', form='unformatted')
         end if
         !-- Write header when first called
         if ( nLogs == 1 ) then
            write(n_rmelt_file) n_theta_max
            write(n_rmelt_file) real(theta_ord(:),outp)
         end if
         write(n_rmelt_file) real(time,outp), real(rmelt(:),outp)
         if ( l_save_out ) close(n_rmelt_file)

         lm00 = lo_map%lm2(0,0) ! l=m=0
         !-- Mean phase field
         call PhiMeanR%compute(osq4pi*real(phi(lm00,:)),n_calls,timePassed,timeNorm)

         !-- Integration of kinetic energy over radius
         ekinL=eScale*rInt_R(ekinLr_global,r,rscheme_oc)
         ekinS=eScale*rInt_R(ekinSr_global,r,rscheme_oc)

         !-- Get the volume of the solid phase
         volS=eScale*rInt_R(volSr_global,r,rscheme_oc)

         !-- Fluxes
         fcmb = -opr * real(ds(lm00,n_r_cmb))*osq4pi*four*pi*r_cmb**2*kappa(n_r_cmb)
         ficb = -opr * real(ds(lm00,n_r_icb))*osq4pi*four*pi*r_icb**2*kappa(n_r_icb)

         !-- Integration of T-St*Phi
         tmp(:)=osq4pi*(real(s(lm00,:))-stef*real(phi(lm00,:)))*r(:)*r(:)
         TPhiOld=TPhi
         TPhi   =four*pi*rInt_R(tmp,r,rscheme_oc)
         dtTPhi =(TPhi-TPhiOld)/timePassed

         !-- Determine the radial level where \phi=0.5
         tmp(:)=osq4pi*real(phi(lm00,:)) ! Reuse tmp as work array
         n_r_phase=2
         do n_r=2,n_r_max
            if ( tmp(n_r) < half .and. tmp(n_r-1) > half ) then
               n_r_phase=n_r
            end if
         end do

         !-- Linear interpolation of melting point
         if ( n_r_phase /= 2 ) then
            slope=(tmp(n_r_phase)-tmp(n_r_phase-1))/(r(n_r_phase)-r(n_r_phase-1))
            intersect=tmp(n_r_phase)-slope*r(n_r_phase)
            rphase=(half-intersect)/slope
            tmp(:)=osq4pi*real(s(lm00,:)) ! Reuse tmp as work array
            slope=(tmp(n_r_phase)-tmp(n_r_phase-1))/(r(n_r_phase)-r(n_r_phase-1))
            intersect=tmp(n_r_phase)-slope*r(n_r_phase)
            tphase=slope*rphase+intersect
         else
            rphase=r_cmb
            tphase=osq4pi*real(s(lm00,n_r_cmb))
         end if

         if ( nLogs > 1 ) then
            if ( l_save_out ) then
               open(newunit=n_phase_file, file=phase_file, status='unknown', &
               &    position='append')
            end if

            write(n_phase_file,'(1P,ES20.12,8ES16.8)')   &
            &     time, rphase, tphase, volS, ekinS, ekinL, fcmb, ficb, dtTPhi

            if ( l_save_out ) close(n_phase_file)
         end if

         if ( l_stop_time ) then
            call PhiMeanR%finalize_SD(timeNorm)
            filename='phiR.'//tag
            open(newunit=filehandle, file=filename, status='unknown')
            do n_r=1,n_r_max
               write(filehandle, '(ES20.10,ES15.7,ES13.5)' )                     &
               &     r(n_r),round_off(PhiMeanR%mean(n_r),maxval(PhiMeanR%mean)), &
               &     round_off(PhiMeanR%SD(n_r),maxval(PhiMeanR%SD))
            end do

            close(filehandle)
         end if

      end if

   end subroutine outPhase
!---------------------------------------------------------------------------
end module outMisc_mod
