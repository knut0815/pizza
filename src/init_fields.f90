module init_fields

   use constants, only: zero, one, two, three, ci, pi
   use blocking, only: nRstart, nRstop
   use communications, only: transp_r2m, r2m_fields
   use radial_functions, only: r, rscheme, or1, or2, beta, dbeta
   use namelists, only: l_start_file, dtMax, init_t, amp_t, init_u, amp_u, &
       &                radratio, r_cmb, r_icb
   use outputs, only: n_log_file
   use parallel_mod, only: rank
   use blocking, only: nMstart, nMstop, nM_per_rank
   use truncation, only: m_max, n_r_max, minc, m2idx, idx2m, n_phi_max
   use useful, only: logWrite, abortRun
   use radial_der, only: get_dr
   use fourier, only: fft
   use checkpoints, only: read_checkpoint
   use time_schemes, only: type_tscheme
   use fields
   use fieldsLast
   use precision_mod

   implicit none

   private

   public :: get_start_fields

contains

   subroutine get_start_fields(time, tscheme)

      !-- Output variables
      real(cp),           intent(out) :: time
      type(type_tscheme), intent(inout) :: tscheme

      !-- Local variables
      integer :: m, n_r, n_m, n_o
      character(len=76) :: message

      if ( l_start_file ) then
         call read_checkpoint(us_Mloc, up_Mloc, dpsi_exp_Mloc, dpsi_imp_Mloc, &
              &               temp_Mloc, dtemp_exp_Mloc, dtemp_imp_Mloc,      &
              &               time, tscheme)
      else
         temp_Mloc(:,:)       =zero
         us_Mloc(:,:)         =zero
         up_Mloc(:,:)         =zero
         psi_Mloc(:,:)        =zero
         dpsi_exp_Mloc(:,:,:) =zero
         dtemp_exp_Mloc(:,:,:)=zero
         dpsi_imp_Mloc(:,:,:) =zero
         dtemp_imp_Mloc(:,:,:)=zero

         time=0.0_cp
         do n_o=1,tscheme%norder_exp
            tscheme%dt(n_o)=dtMax
         end do

         if (rank == 0) write(message,'(''! Using dtMax time step:'',ES16.6)') dtMax
         call logWrite(message, n_log_file)
      end if

      !-- Initialize the weights of the time scheme
      call tscheme%set_weights()

      if ( init_t /= 0 ) call initT(temp_Mloc)

      if ( init_u /= 0 ) call initU(us_Mloc, up_Mloc)

      !-- Reconstruct missing fields, dtemp_Mloc, om_Mloc
      call get_dr(temp_Mloc, dtemp_Mloc, nMstart, nMstop, n_r_max, rscheme)
      call get_dr(up_Mloc, work_Mloc, nMstart, nMstop, n_r_max, rscheme)
      do n_r=1,n_r_max
         do n_m=nMstart,nMstop
            m = idx2m(n_m)
            om_Mloc(n_m,n_r)=work_Mloc(n_m,n_r)+or1(n_r)*up_Mloc(n_m,n_r)- &
            &                     or1(n_r)*ci*real(m,cp)*us_Mloc(n_m,n_r)
         end do
      end do

   end subroutine get_start_fields
!----------------------------------------------------------------------------------
   subroutine initT(temp_Mloc)

      !-- Output variables
      complex(cp), intent(inout) :: temp_Mloc(nMstart:nMstop, n_r_max)

      !-- Local variables
      integer :: m_pertu, n_r, idx, n_phi, n_m
      real(cp) :: x, c_r, rdm
      real(cp) :: t1(n_r_max)
      real(cp) :: phi, phi0
      real(cp) :: phi_func(n_phi_max)

      !-- Radial dependence of perturbation in t1:
      do n_r=1,n_r_max
         x=two*r(n_r)-r_cmb-r_icb
         t1(n_r)=sin(pi*(r(n_r)-r_icb))
      end do

      if ( init_t > 0 ) then ! Initialize a peculiar m mode
         
         m_pertu = init_t

         if ( mod(m_pertu,minc) /= 0 ) then
            write(*,*) '! Wave number of mode for temperature initialisation'
            write(*,*) '! not compatible with phi-symmetry:',m_pertu
            call abortRun('Stop run in init')
         end if
         if ( m_pertu > m_max ) then
            write(*,*) '! Degree of mode for temperature initialisation'
            write(*,*) '! > m_max  !',m_pertu
            call abortRun('Stop run in init')
         end if

         idx = m2idx(m_pertu)
         if ( idx >= nMstart .and. idx <= nMstop ) then
            do n_r=1,n_r_max
               c_r=t1(n_r)*amp_t
               temp_Mloc(idx,n_r)=temp_Mloc(idx,n_r)+cmplx(c_r,0.0_cp,kind=cp)
            end do
         end if

      else if ( init_t == -1 ) then ! bubble = Gaussian in r and phi

         phi0 = pi/minc
         do n_r=nRstart,nRstop
            c_r = amp_t*exp(-(r(n_r)-r_cmb+0.5_cp)**2/0.1_cp**2)
            do n_phi=1,n_phi_max
               phi = (n_phi-1)*two*pi/minc/(n_phi_max)
               phi_func(n_phi)=c_r*exp(-(phi-phi0)**2/(0.2_cp/minc)**2)
            end do

            !-- temp_Rloc is used as a work r-distributed array here
            call fft(phi_func, temp_Rloc(:,n_r))
         end do

         !-- MPI transpose is needed here
         call transp_r2m(r2m_fields, temp_Rloc, work_Mloc)

         do n_r=1,n_r_max
            do n_m=nMstart,nMstop
               temp_Mloc(n_m,n_r) = temp_Mloc(n_m,n_r)+work_Mloc(n_m,n_r)
            end do
         end do

      else ! random noise

         do n_r=1,n_r_max
            t1(n_r)=sin(pi*(r(n_r)-r_icb))
         end do

         do n_r=1,n_r_max
            do n_m=nMstart, nMstop
               m_pertu = idx2m(n_m)
               if ( m_pertu > 0 ) then
                  call random_number(rdm)
                  temp_Mloc(n_m, n_r) = amp_t*rdm*m_pertu**(-1.5_cp)*t1(n_r)
               end if
            end do
         end do

      end if

   end subroutine initT
!----------------------------------------------------------------------------------
   subroutine initU(us_Mloc, up_Mloc)

      !-- Output variables
      complex(cp), intent(inout) :: us_Mloc(nMstart:nMstop, n_r_max)
      complex(cp), intent(inout) :: up_Mloc(nMstart:nMstop, n_r_max)

      !-- Local variables
      integer :: m_pertu, n_r, idx, m, n_m
      real(cp) :: c_r
      real(cp) :: u1(n_r_max)


      !-- Radial dependence of perturbation in t1:
      do n_r=1,n_r_max
         u1(n_r)=sin(pi*(r(n_r)-r_icb))
      end do


      if ( init_u > 0 ) then
         
         m_pertu = init_u

         if ( mod(m_pertu,minc) /= 0 ) then
            write(*,*) '! Wave number of mode for velocity initialisation'
            write(*,*) '! not compatible with phi-symmetry:',m_pertu
            call abortRun('Stop run in init')
         end if
         if ( m_pertu > m_max ) then
            write(*,*) '! Degree of mode for velocity initialisation'
            write(*,*) '! > m_max  !',m_pertu
            call abortRun('Stop run in init')
         end if

         idx = m2idx(m_pertu)
         if ( idx >= nMstart .and. idx <= nMstop ) then
            do n_r=1,n_r_max
               c_r=u1(n_r)*amp_u
               us_Mloc(idx,n_r)=us_Mloc(idx,n_r)+cmplx(c_r,0.0_cp,kind=cp)
            end do
         end if

         !-- Get the corresponding vorticity
         do n_r=1,n_r_max
            do n_m=nMstart, nMstop
               m = idx2m(n_m)
               om_Mloc(n_m,n_r)=-ci*m*or1(n_r)*us_Mloc(n_m,n_r)
            end do
         end do

      else ! initialize an axisymmetric vphi

         idx = m2idx(0)
         if ( idx >= nMstart .and. idx <= nMstop ) then
            do n_r=1,n_r_max
               c_r=amp_t*sin(pi*(r(n_r)-r_icb))
               up_Mloc(idx,n_r)=up_Mloc(idx,n_r)+cmplx(c_r,0.0_cp,kind=cp)
            end do
         end if

      end if

   end subroutine initU
!----------------------------------------------------------------------------------
end module init_fields
