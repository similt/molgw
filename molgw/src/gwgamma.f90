!=========================================================================
! This file is part of MOLGW.
! Author: Fabien Bruneval
!
! This file contains the calculation of the GW self-energy with vertex function
! within different flavors: G0W0GAMMA0 G0W0SOX0
!
!=========================================================================
subroutine gwgamma_selfenergy(nstate,gwmethod,basis,occupation,energy,exchange_m_vxc_diag,c_matrix,wpol,selfenergy,energy_gw)
 use m_definitions
 use m_mpi
 use m_timing 
 use m_inputparam
 use m_warning,only: issue_warning,msg
 use m_basis_set
 use m_spectral_function
 use m_eri_ao_mo
 use m_selfenergy_tools
 use m_tddft_fxc
 implicit none

 integer,intent(in)                 :: nstate,gwmethod
 type(basis_set)                    :: basis
 real(dp),intent(in)                :: occupation(nstate,nspin),energy(nstate,nspin),exchange_m_vxc_diag(nstate,nspin)
 real(dp),intent(in)                :: c_matrix(basis%nbf,nstate,nspin)
 type(spectral_function),intent(in) :: wpol
 real(dp),intent(out)               :: selfenergy(basis%nbf,basis%nbf,nspin)
 real(dp),intent(out)               :: energy_gw
!=====
 integer               :: nomegai
 integer               :: iomegai
 real(dp),allocatable  :: omegai(:)
 real(dp),allocatable  :: selfenergy_omega(:,:,:,:)
 real(dp),allocatable  :: selfenergy_omega_gw(:,:,:,:)
 real(dp),allocatable  :: selfenergy_omega_gamma(:,:,:,:)
 real(dp),allocatable  :: selfenergy_omega_sox(:,:,:,:)
 integer               :: astate,bstate,cstate
 integer               :: istate,jstate,kstate,ispin,spole
 integer               :: mstate
 real(dp),allocatable  :: bra(:,:)
 real(dp)              :: vcoul,vcoul1,vcoul2
 real(dp)              :: energy_qp(nstate,nspin)
 real(dp),allocatable  :: zz(:,:)
 real(dp)              :: energy_qp_new(nstate,nspin),energy_qp_z(nstate,nspin)
 integer               :: reading_status
 integer               :: selfenergyfile
 real(dp)              :: pole_s
 real(dp)              :: fxc
! logical,parameter     :: tddft_kernel = .FALSE.
 logical,parameter     :: tddft_kernel = .TRUE.
!=====

 call start_clock(timing_gwgamma)

 write(stdout,*)
 select case(gwmethod)
 case(G0W0SOX0)
   write(stdout,*) 'Perform a one-shot G0W0SOX0 calculation'
 case(G0W0GAMMA0)
   if( calc_type%read_energy_qp ) then
     write(stdout,*) 'Perform an eigenvalue-self-consistent GWGAMMA calculation'
   else
     write(stdout,*) 'Perform a one-shot G0W0GAMMA0 calculation'
   endif
 end select


 if( tddft_kernel ) then
   write(stdout,*) 'Include a TDDFT kernel contribution to the vertex'
   write(stdout,'(1x,a,f12.4)') 'Exact-exchange amount: ',alpha_hybrid
   call prepare_tddft(nstate,basis,c_matrix,occupation)
 endif

 ! Set the range of states on which to evaluate the self-energy
 call selfenergy_set_state_ranges(nstate,occupation)

 if(has_auxil_basis) then
   call calculate_eri_3center_eigen(basis%nbf,nstate,c_matrix,ncore_G+1,nvirtual_G-1,ncore_G+1,nvirtual_G-1)
 else
   stop'NOT implemented'
 endif


 call clean_allocate('Temporary array',bra,ncore_G+1,nvirtual_G-1,ncore_G+1,MAX(nhomo_G,nsemax))

 energy_gw = 0.0_dp

 write(msg,'(es9.2)') AIMAG(ieta)
 call issue_warning('small complex number is '//msg)


 nomegai = nomega_sigma/2
 allocate(omegai(-nomegai:nomegai))
 do iomegai=-nomegai,nomegai
   omegai(iomegai) = step_sigma * iomegai
 enddo


 !
 ! Which calculation type needs to update energy_qp
 !
 if( calc_type%read_energy_qp ) then

   call read_energy_qp(nstate,energy_qp,reading_status)
   if(reading_status/=0) then
     call issue_warning('File energy_qp not found: assuming 1st iteration')
     energy_qp(:,:) = energy(:,:)
   endif

 else

   energy_qp(:,:) = energy(:,:)

 endif

 !
 !
 allocate(selfenergy_omega(-nomegai:nomegai,nsemin:nsemax,1,nspin))
 allocate(selfenergy_omega_gamma(-nomegai:nomegai,nsemin:nsemax,1,nspin))
 allocate(selfenergy_omega_sox(-nomegai:nomegai,nsemin:nsemax,1,nspin))

 if( ALLOCATED(selfenergy_omega_gamma) ) selfenergy_omega_gamma(:,:,:,:)  = 0.0_dp
 if( ALLOCATED(selfenergy_omega_sox) )   selfenergy_omega_sox(:,:,:,:)  = 0.0_dp


#if 1
 write(stdout,*) 'Calculate SOX'

 do ispin=1,nspin

   !==========================
   do bstate=ncore_G+1,nvirtual_G-1
     if( (spin_fact - occupation(bstate,ispin)) / spin_fact < completely_empty) cycle
     if( MODULO( bstate-(ncore_G+1) , nproc_ortho ) /= rank_ortho ) cycle

     do istate=ncore_G+1,nvirtual_G-1
       if( occupation(istate,ispin) / spin_fact < completely_empty ) cycle
       do kstate=ncore_G+1,nvirtual_G-1
         if( occupation(kstate,ispin) / spin_fact < completely_empty ) cycle

         do mstate=nsemin,nsemax

           vcoul1 = eri_eigen_ri(mstate,istate,ispin,bstate,kstate,ispin)
           vcoul2 = eri_eigen_ri(istate,bstate,ispin,kstate,mstate,ispin)
           if( tddft_kernel ) then
             fxc = eval_fxc_rks_singlet(istate,bstate,ispin,kstate,mstate,ispin)
             call xsum_grid(fxc)
             vcoul2 = alpha_hybrid * vcoul2 - fxc

!             if( ABS( eri_eigen_ri(istate,bstate,ispin,kstate,mstate,ispin) -vcoul2)> 0.10 ) then
!               write(*,'(4(i4,1x),4(1x,f12.6))') istate,bstate,kstate,mstate, &
!                  eri_eigen_ri(istate,bstate,ispin,kstate,mstate,ispin), &
!                  vcoul2
!               write(*,*) 'Hack'
!               vcoul2 = eri_eigen_ri(istate,bstate,ispin,kstate,mstate,ispin)
!             endif

           endif
           !
           ! calculate only the diagonal !
           do iomegai=-nomegai,nomegai
             selfenergy_omega_sox(iomegai,mstate,1,ispin) = selfenergy_omega_sox(iomegai,mstate,1,ispin) &
                 - vcoul1 * vcoul2            &
                   *  REAL(  1.0_dp / ( energy_qp(mstate,ispin) + omegai(iomegai) - energy_qp(istate,ispin) - energy_qp(kstate,ispin) + energy_qp(bstate,ispin) - ieta )  , dp ) 
           enddo
         enddo

       enddo
     enddo
   enddo

   !==========================
   do cstate=ncore_G+1,nvirtual_G-1
     if( (spin_fact - occupation(cstate,ispin)) / spin_fact < completely_empty) cycle
     if( MODULO( cstate-(ncore_G+1) , nproc_ortho ) /= rank_ortho ) cycle

     do jstate=ncore_G+1,nvirtual_G-1
       if( occupation(jstate,ispin) / spin_fact < completely_empty ) cycle
       do astate=ncore_G+1,nvirtual_G-1
         if( (spin_fact - occupation(astate,ispin)) / spin_fact < completely_empty) cycle

         do mstate=nsemin,nsemax

           vcoul1 = eri_eigen_ri(mstate,astate,ispin,jstate,cstate,ispin)
           vcoul2 = eri_eigen_ri(astate,jstate,ispin,cstate,mstate,ispin)
           if( tddft_kernel ) then
             fxc = eval_fxc_rks_singlet(astate,jstate,ispin,cstate,mstate,ispin)
             call xsum_grid(fxc)
             vcoul2 = alpha_hybrid * vcoul2 - fxc

!             if( ABS( eri_eigen_ri(astate,jstate,ispin,cstate,mstate,ispin) -vcoul2 )> 0.10 ) then
!               write(*,'(4(i4,1x),4(1x,f12.6))') astate,jstate,cstate,mstate, &
!                  eri_eigen_ri(astate,jstate,ispin,cstate,mstate,ispin), &
!                  vcoul2
!!               write(*,*) 'Hack'
!!               vcoul2 =  eri_eigen_ri(astate,jstate,ispin,cstate,mstate,ispin)
!             endif

           endif
           !
           ! calculate only the diagonal !
           do iomegai=-nomegai,nomegai
             selfenergy_omega_sox(iomegai,mstate,1,ispin) = selfenergy_omega_sox(iomegai,mstate,1,ispin) &
                 - vcoul1 * vcoul2            &
                   *  REAL(  1.0_dp / ( energy_qp(mstate,ispin) + omegai(iomegai) - energy_qp(astate,ispin) - energy_qp(cstate,ispin) + energy_qp(jstate,ispin) + ieta )  , dp ) 
           enddo
         enddo

       enddo
     enddo
   enddo


 enddo

 call xsum_ortho(selfenergy_omega_sox)

#else

 call static_polarizability(nstate,occupation,energy_qp,wpol)

 write(stdout,*) 'Calculate static SOSEX'

 do ispin=1,nspin

   !==========================
   do kstate=ncore_G+1,nvirtual_G-1
     if( occupation(kstate,ispin) / spin_fact < completely_empty ) cycle
     do istate=ncore_G+1,nvirtual_G-1
       if( occupation(istate,ispin) / spin_fact < completely_empty ) cycle
       do bstate=ncore_G+1,nvirtual_G-1
         if( (spin_fact - occupation(bstate,ispin)) / spin_fact < completely_empty) cycle

         do mstate=nsemin,nsemax

           vcoul1 = eri_eigen_ri(mstate,istate,ispin,bstate,kstate,ispin)   &
                   +DOT_PRODUCT( eri_3center_eigen(:,mstate,istate,ispin) , &
                                 MATMUL( wpol%w0(:,:) , eri_3center_eigen(:,bstate,kstate,ispin) ) )
!FBFB           vcoul2 = eri_eigen_ri(istate,bstate,ispin,kstate,mstate,ispin)
           vcoul2 = eri_eigen_ri(istate,bstate,ispin,kstate,mstate,ispin)   &
                   +DOT_PRODUCT( eri_3center_eigen(:,istate,bstate,ispin) , &
                                 MATMUL( wpol%w0(:,:) , eri_3center_eigen(:,kstate,mstate,ispin) ) )
           !
           ! calculate only the diagonal !
           do iomegai=-nomegai,nomegai
             selfenergy_omega_sox(iomegai,mstate,1,ispin) = selfenergy_omega_sox(iomegai,mstate,1,ispin) &
                 - vcoul1 * vcoul2            &
                   *  REAL(  1.0_dp / ( energy_qp(mstate,ispin) + omegai(iomegai) - energy_qp(istate,ispin) - energy_qp(kstate,ispin) + energy_qp(bstate,ispin) - ieta )  , dp ) 
           enddo
         enddo

       enddo
     enddo
   enddo


   !==========================
   do cstate=ncore_G+1,nvirtual_G-1
     if( (spin_fact - occupation(cstate,ispin)) / spin_fact < completely_empty) cycle
     do jstate=ncore_G+1,nvirtual_G-1
       if( occupation(jstate,ispin) / spin_fact < completely_empty ) cycle
       do astate=ncore_G+1,nvirtual_G-1
         if( (spin_fact - occupation(astate,ispin)) / spin_fact < completely_empty) cycle

         do mstate=nsemin,nsemax

           vcoul1 = eri_eigen_ri(mstate,astate,ispin,jstate,cstate,ispin)   &
                   +DOT_PRODUCT( eri_3center_eigen(:,mstate,astate,ispin) , &
                                 MATMUL( wpol%w0(:,:) , eri_3center_eigen(:,jstate,cstate,ispin) ) )
!FBFB           vcoul2 = eri_eigen_ri(astate,jstate,ispin,cstate,mstate,ispin)
           vcoul2 = eri_eigen_ri(astate,jstate,ispin,cstate,mstate,ispin)   &
                   +DOT_PRODUCT( eri_3center_eigen(:,jstate,astate,ispin) , &
                                 MATMUL( wpol%w0(:,:) , eri_3center_eigen(:,mstate,cstate,ispin) ) )
           !
           ! calculate only the diagonal !
           do iomegai=-nomegai,nomegai
             selfenergy_omega_sox(iomegai,mstate,1,ispin) = selfenergy_omega_sox(iomegai,mstate,1,ispin) &
                 - vcoul1 * vcoul2            &
                   *  REAL(  1.0_dp / ( energy_qp(mstate,ispin) + omegai(iomegai) - energy_qp(astate,ispin) - energy_qp(cstate,ispin) + energy_qp(jstate,ispin) + ieta )  , dp ) 
           enddo
         enddo

       enddo
     enddo
   enddo


 enddo
#endif


 if( gwmethod == G0W0GAMMA0 ) then 

   write(stdout,*) 'Calculate dynamical SOSEX'

  
   do ispin=1,nspin
  
     do spole=1,wpol%npole_reso
  
       if( MODULO( spole - 1 , nproc_ortho ) /= rank_ortho ) cycle
       write(stdout,*) 'SOSEX W poles:',spole,' / ',wpol%npole_reso

       pole_s = wpol%pole(spole)
  
       do mstate=ncore_G+1,MAX(nhomo_G,nsemax)
         ! Here transform (sqrt(v) * chi * sqrt(v)) into  (v * chi * v)
         bra(:,mstate)     = MATMUL( wpol%residu_left(:,spole) , eri_3center_eigen(:,:,mstate,ispin) )
       enddo
       call xsum_auxil(bra)
  
  
       !==========================
       do istate=ncore_G+1,nvirtual_G-1
         if( occupation(istate,ispin) / spin_fact < completely_empty ) cycle
         do bstate=ncore_G+1,nvirtual_G-1
           if( (spin_fact - occupation(bstate,ispin)) / spin_fact < completely_empty) cycle
           do kstate=ncore_G+1,nvirtual_G-1
             if( occupation(kstate,ispin) / spin_fact < completely_empty ) cycle
  
             !
             ! calculate only the diagonal !
             do mstate=nsemin,nsemax
  
               vcoul = eri_eigen_ri(istate,kstate,ispin,bstate,mstate,ispin)
               if( tddft_kernel ) then
                 fxc = eval_fxc_rks_singlet(istate,kstate,ispin,bstate,mstate,ispin)
                 call xsum_grid(fxc)
                 vcoul = alpha_hybrid * vcoul - fxc
               endif

               do iomegai=-nomegai,nomegai
                 selfenergy_omega_gamma(iomegai,mstate,1,ispin) = selfenergy_omega_gamma(iomegai,mstate,1,ispin) &
                          - bra(kstate,mstate) * bra(bstate,istate) * vcoul                          &  
                            *  REAL(  1.0_dp / ( energy_qp(mstate,ispin) + omegai(iomegai) - energy_qp(kstate,ispin) + pole_s - ieta )  , dp )  &
                            *  REAL(  1.0_dp / ( -pole_s + energy_qp(istate,ispin) - energy_qp(bstate,ispin) + ieta )  , dp ) 
               enddo
             enddo
  
           enddo
         enddo
       enddo
  
       !==========================
       do istate=ncore_G+1,nvirtual_G-1
         if( occupation(istate,ispin) / spin_fact < completely_empty ) cycle
         do bstate=ncore_G+1,nvirtual_G-1
           if( (spin_fact - occupation(bstate,ispin)) / spin_fact < completely_empty ) cycle
           do cstate=ncore_G+1,nvirtual_G-1
             if( (spin_fact - occupation(cstate,ispin)) / spin_fact < completely_empty ) cycle
  
             !
             ! calculate only the diagonal !
             do mstate=nsemin,nsemax
  
               vcoul = eri_eigen_ri(istate,cstate,ispin,bstate,mstate,ispin)
               if( tddft_kernel ) then
                 fxc = eval_fxc_rks_singlet(istate,cstate,ispin,bstate,mstate,ispin)
                 call xsum_grid(fxc)
                 vcoul = alpha_hybrid * vcoul - fxc
               endif

               do iomegai=-nomegai,nomegai
                 selfenergy_omega_gamma(iomegai,mstate,1,ispin) = selfenergy_omega_gamma(iomegai,mstate,1,ispin) &
                          - bra(cstate,mstate) * bra(bstate,istate) * vcoul                          &  
                            *  REAL(  1.0_dp / ( energy_qp(mstate,ispin) + omegai(iomegai) - energy_qp(cstate,ispin) - pole_s + ieta )  , dp )  &
                            *  REAL(  1.0_dp / ( energy_qp(mstate,ispin) + omegai(iomegai) - energy_qp(cstate,ispin) + energy_qp(istate,ispin) - energy_qp(bstate,ispin) + ieta )  , dp ) 
  
  
                 selfenergy_omega_gamma(iomegai,mstate,1,ispin) = selfenergy_omega_gamma(iomegai,mstate,1,ispin) &
                          + bra(cstate,mstate) * bra(bstate,istate) * vcoul                          &  
                            *  REAL(  1.0_dp / ( energy_qp(mstate,ispin) + omegai(iomegai) - energy_qp(bstate,ispin) - energy_qp(cstate,ispin) + energy_qp(istate,ispin) + ieta )  , dp )  &
                            *  REAL(  1.0_dp / ( energy_qp(bstate,ispin) - energy_qp(istate,ispin) + pole_s - ieta )  , dp ) 
  
               enddo
             enddo
  
           enddo
         enddo
       enddo
  
       !==========================
       do astate=ncore_G+1,nvirtual_G-1
         if( (spin_fact - occupation(astate,ispin)) / spin_fact < completely_empty  ) cycle
         do jstate=ncore_G+1,nvirtual_G-1
           if( occupation(jstate,ispin) / spin_fact < completely_empty ) cycle
           do kstate=ncore_G+1,nvirtual_G-1
             if( occupation(kstate,ispin) / spin_fact < completely_empty ) cycle
  
             !
             ! calculate only the diagonal !
             do mstate=nsemin,nsemax
  
               vcoul = eri_eigen_ri(astate,kstate,ispin,jstate,mstate,ispin)
               if( tddft_kernel ) then
                 fxc = eval_fxc_rks_singlet(astate,kstate,ispin,jstate,mstate,ispin)
                 call xsum_grid(fxc)
                 vcoul = alpha_hybrid * vcoul - fxc
               endif

               do iomegai=-nomegai,nomegai
                 selfenergy_omega_gamma(iomegai,mstate,1,ispin) = selfenergy_omega_gamma(iomegai,mstate,1,ispin) &
                          - bra(kstate,mstate) * bra(astate,jstate) * vcoul                          &  
                            *  REAL(  1.0_dp / ( energy_qp(mstate,ispin) + omegai(iomegai) - energy_qp(kstate,ispin) + energy_qp(astate,ispin) - energy_qp(jstate,ispin)  - ieta )  , dp )  &
                            *  REAL(  1.0_dp / ( energy_qp(jstate,ispin) - energy_qp(astate,ispin) - pole_s + ieta )  , dp ) 
  
                 selfenergy_omega_gamma(iomegai,mstate,1,ispin) = selfenergy_omega_gamma(iomegai,mstate,1,ispin) &
                          + bra(kstate,mstate) * bra(astate,jstate) * vcoul                          &  
                            *  REAL(  1.0_dp / ( energy_qp(mstate,ispin) + omegai(iomegai) - energy_qp(kstate,ispin) + energy_qp(astate,ispin) - energy_qp(jstate,ispin)  - ieta )  , dp )  &
                            *  REAL(  1.0_dp / ( energy_qp(mstate,ispin) + omegai(iomegai) - energy_qp(kstate,ispin) + pole_s - ieta )  , dp ) 
  
  
               enddo
             enddo
  
           enddo
         enddo
       enddo
  
       !==========================
       do astate=ncore_G+1,nvirtual_G-1
         if( (spin_fact - occupation(astate,ispin)) / spin_fact < completely_empty  ) cycle
         do jstate=ncore_G+1,nvirtual_G-1
           if( occupation(jstate,ispin) / spin_fact < completely_empty ) cycle
           do cstate=ncore_G+1,nvirtual_G-1
             if( (spin_fact - occupation(cstate,ispin)) / spin_fact < completely_empty ) cycle
  
             !
             ! calculate only the diagonal !
             do mstate=nsemin,nsemax
  
               vcoul = eri_eigen_ri(astate,cstate,ispin,jstate,mstate,ispin)
               if( tddft_kernel ) then
                 fxc = eval_fxc_rks_singlet(astate,cstate,ispin,jstate,mstate,ispin)
                 call xsum_grid(fxc)
                 vcoul = alpha_hybrid * vcoul - fxc
               endif

               do iomegai=-nomegai,nomegai
                 selfenergy_omega_gamma(iomegai,mstate,1,ispin) = selfenergy_omega_gamma(iomegai,mstate,1,ispin) &
                          + bra(cstate,mstate) * bra(astate,jstate) * vcoul                          &  
                            *  REAL(  1.0_dp / ( energy_qp(mstate,ispin) + omegai(iomegai) - energy_qp(cstate,ispin) - pole_s + ieta )  , dp )  &
                            *  REAL(  1.0_dp / ( pole_s + energy_qp(astate,ispin) - energy_qp(jstate,ispin) - ieta )  , dp ) 
  
               enddo
             enddo
  
           enddo
         enddo
       enddo
  
  
  
     enddo !spole
   enddo !ispin

   call xsum_ortho(selfenergy_omega_gamma)

 endif


 write(stdout,'(a)') ' Sigma_c(omega) is calculated'

 allocate(selfenergy_omega_gw(-nomegai:nomegai,nsemin:nsemax,1,nspin))

 if( is_iomaster ) then
   open(newunit=selfenergyfile,file='g0w0.dat',status='old',form='unformatted')
   do ispin=1,nspin
     do astate=nsemin,nsemax
       read(selfenergyfile) selfenergy_omega_gw(:,astate,1,ispin)
     enddo
   enddo
   close(selfenergyfile,status='delete')
 else
   selfenergy_omega_gw(:,:,:,:) = 0.0_dp
 endif
 call xsum_world(selfenergy_omega_gw)


 forall(astate=nsemin:nsemax)
   selfenergy_omega(:,astate,1,:) = selfenergy_omega_gw(:,astate,1,:) + selfenergy_omega_sox(:,astate,1,:) + selfenergy_omega_gamma(:,astate,1,:)
 end forall


 if( print_sigma_) then
   call write_selfenergy_omega('selfenergy_sox'    ,nstate,energy_qp,exchange_m_vxc_diag,SIZE(omegai),omegai,nsemin,nsemax,selfenergy_omega_sox  (:,:,1,:))
   call write_selfenergy_omega('selfenergy_gamma'  ,nstate,energy_qp,exchange_m_vxc_diag,SIZE(omegai),omegai,nsemin,nsemax,selfenergy_omega_gamma(:,:,1,:))
   call write_selfenergy_omega('selfenergy_gwgamma',nstate,energy_qp,exchange_m_vxc_diag,SIZE(omegai),omegai,nsemin,nsemax,selfenergy_omega      (:,:,1,:))
 endif
 
 ! Only had the diagonal calculated...
 selfenergy(:,:,:) = 0.0_dp
 forall(astate=nsemin:nsemax)
   selfenergy(astate,astate,:) = selfenergy_omega(0,astate,1,:)
 end forall


 write(stdout,'(/,a)') ' G0W0Gamma0 self-energy contributions at E0 (eV)'
 if(nspin==1) then
   write(stdout,'(a)') '   #          E0        SigX-Vxc    SigC_G0W0    SigC_SOX   SigC_Gamma0   SigC_TOT'
 else
   write(stdout,'(a)') &
     '   #                E0                      SigX-Vxc                    SigC_G0W0            SigC_SOX             SigC_Gamma0                SigC_TOT'
 endif

 do astate=nsemin,nsemax
   write(stdout,'(i4,1x,20(1x,f12.6))') astate,energy_qp(astate,:)*Ha_eV,          & 
                                        exchange_m_vxc_diag(astate,:)*Ha_eV,       &
                                        selfenergy_omega_gw(0,astate,1,:)*Ha_eV,   &
                                        selfenergy_omega_sox(0,astate,1,:)*Ha_eV,  &
                                        selfenergy_omega_gamma(0,astate,1,:)*Ha_eV,&
                                        selfenergy_omega(0,astate,1,:)*Ha_eV
 enddo


 allocate(zz(nsemin:nsemax,nspin))

 call find_qp_energy_linearization(nomegai,omegai,nsemin,nsemax,selfenergy_omega(:,:,1,:),nstate,exchange_m_vxc_diag,energy,energy_qp_z,zz)
 call find_qp_energy_graphical    (nomegai,omegai,nsemin,nsemax,selfenergy_omega(:,:,1,:),nstate,exchange_m_vxc_diag,energy,energy_qp_new)

 select case(gwmethod)
 case(G0W0SOX0)
   call output_qp_energy('G0W0SOX0',nstate,nsemin,nsemax,energy_qp,exchange_m_vxc_diag,selfenergy_omega(0,:,1,:),energy_qp_z,energy_qp_new,zz)
 case(G0W0GAMMA0)
   call output_qp_energy('G0W0Gamma0',nstate,nsemin,nsemax,energy_qp,exchange_m_vxc_diag,selfenergy_omega(0,:,1,:),energy_qp_z,energy_qp_new,zz)
 end select
 deallocate(zz)

 call write_energy_qp(nstate,energy_qp_new)




 !
 ! Output the new HOMO and LUMO energies
 !
 select case(gwmethod)
 case(G0W0SOX0)
   call output_new_homolumo('G0W0SOX0',nstate,occupation,energy_qp_new,nsemin,nsemax)
 case(G0W0GAMMA0)
   call output_new_homolumo('G0W0Gamma0',nstate,occupation,energy_qp_new,nsemin,nsemax)
 end select

 call clean_deallocate('Temporary array',bra)

 if(has_auxil_basis) then
   call destroy_eri_3center_eigen()
 endif

 if(ALLOCATED(omegai)) deallocate(omegai)
 if(ALLOCATED(selfenergy_omega)) deallocate(selfenergy_omega)

 if( tddft_kernel ) then
   call destroy_tddft()
 endif

 call stop_clock(timing_gwgamma)


end subroutine gwgamma_selfenergy


!=========================================================================
