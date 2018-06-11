module mloop_mod

   use time_schemes, only: type_tscheme
   use time_array, only: type_tarray
   use precision_mod
   use truncation, only: n_r_max
   use outputs, only: vp_bal_type
   use blocking, only: nMstart, nMstop
   use namelists, only: l_direct_solve, l_cheb_coll
   use update_temp_coll, only: update_temp_co, get_temp_rhs_imp_coll
   use update_temp_integ, only: update_temp_int, get_temp_rhs_imp_int
   use update_psi_integ_smat, only: update_psi_int_smat
   use update_psi_integ_dmat, only: update_psi_int_dmat
   use update_psi_coll_dmat, only: update_om_coll_dmat
   use update_psi_coll_smat, only: update_om_coll_smat

   implicit none

   private

   public :: mloop

contains 

   subroutine mloop(temp_Mloc, dtemp_Mloc, psi_Mloc, om_Mloc,  dom_Mloc, us_Mloc, up_Mloc, &
              &     dVsT_Mloc, dVsOm_Mloc, buo_Mloc, dTdt, dpsidt, vp_bal, tscheme,        &
              &     lMat, l_log_next, l_vphi_bal_calc, run_time_solve, n_solve_calls,      &
              &     run_time_lu, n_lu_calls, run_time_dct, n_dct_calls)

      !-- Input variables
      class(type_tscheme), intent(in) :: tscheme
      logical,             intent(in) :: lMat
      logical,             intent(in) :: l_vphi_bal_calc
      logical,             intent(in) :: l_log_next
      complex(cp),         intent(inout) :: buo_Mloc(nMstart:nMstop,n_r_max)

      !-- Output variables
      complex(cp),       intent(out) :: temp_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: dtemp_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: psi_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: om_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(out) :: dom_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(inout) :: us_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(inout) :: up_Mloc(nMstart:nMstop,n_r_max)
      type(vp_bal_type), intent(inout) :: vp_bal
      type(type_tarray), intent(inout) :: dpsidt
      type(type_tarray), intent(inout) :: dTdt
      complex(cp),       intent(inout) :: dVsT_Mloc(nMstart:nMstop,n_r_max)
      complex(cp),       intent(inout) :: dVsOm_Mloc(nMstart:nMstop,n_r_max)
      real(cp),          intent(inout) :: run_time_solve
      integer,           intent(inout) :: n_solve_calls
      real(cp),          intent(inout) :: run_time_lu
      integer,           intent(inout) :: n_lu_calls
      real(cp),          intent(inout) :: run_time_dct
      integer,           intent(inout) :: n_dct_calls


     if ( l_cheb_coll ) then
         call update_temp_co(us_Mloc, temp_Mloc, dtemp_Mloc, dVsT_Mloc,       &
              &              buo_Mloc, dTdt, tscheme, lMat, l_log_next)
         if ( l_direct_solve ) then
            call update_om_coll_smat(psi_Mloc, om_Mloc, dom_Mloc, us_Mloc,    &
                 &                   up_Mloc, dVsOm_Mloc, buo_Mloc, dpsidt,   &
                 &                   vp_bal, tscheme, lMat, l_vphi_bal_calc,  &
                 &                   run_time_solve, n_solve_calls,           &
                 &                   run_time_lu, n_lu_calls, run_time_dct,   &
                 &                   n_dct_calls)
         else
            call update_om_coll_dmat(psi_Mloc, om_Mloc, dom_Mloc, us_Mloc,    &
                 &                   up_Mloc, dVsOm_Mloc, buo_Mloc, dpsidt,   &
                 &                   vp_bal, tscheme, lMat, l_vphi_bal_calc,  &
                 &                   run_time_solve, n_solve_calls,           &
                 &                   run_time_lu, n_lu_calls, run_time_dct,   &
                 &                   n_dct_calls)
         end if
      else
         call update_temp_int(psi_Mloc, temp_Mloc, dtemp_Mloc, dVsT_Mloc,     &
              &               buo_Mloc, dTdt, tscheme, lMat, l_log_next)
         if ( l_direct_solve ) then
            call update_psi_int_smat(psi_Mloc, om_Mloc, us_Mloc, up_Mloc,     &
              &                      dVsOm_Mloc, buo_Mloc, dpsidt, vp_bal,    &
              &                      tscheme, lMat, l_vphi_bal_calc,          &
              &                      run_time_solve, n_solve_calls,           &
              &                      run_time_lu, n_lu_calls, run_time_dct,   &
              &                      n_dct_calls)
         else
            call update_psi_int_dmat(psi_Mloc, om_Mloc, us_Mloc, up_Mloc,     &
              &                      dVsOm_Mloc, buo_Mloc, dpsidt, vp_bal,    &
              &                      tscheme, lMat, l_vphi_bal_calc,          &
              &                      run_time_solve, n_solve_calls,           &
              &                      run_time_lu, n_lu_calls, run_time_dct,   &
              &                      n_dct_calls)
         end if
      end if

   end subroutine mloop

end module mloop_mod
