!=========================================================================
#include "macros.h"
!=========================================================================
module m_basis_set
 use m_definitions
 use m_mpi
 use m_timing
 use m_warning
 use m_tools, only: element_name,diagonalize,invert
 use m_gaussian
 use m_atoms

 real(dp),parameter             :: FILTERED_EIGENVALUE=1.0d-8 

 integer,parameter              :: CARTESIAN=1
 integer,parameter              :: PURE     =2

#if 0
 real(dp),allocatable           :: cart_to_pure_0(:,:)
 real(dp),allocatable           :: cart_to_pure_1(:,:)
 real(dp),allocatable           :: cart_to_pure_2(:,:)
 real(dp),allocatable           :: cart_to_pure_3(:,:)
 real(dp),allocatable           :: cart_to_pure_4(:,:)
 real(dp),allocatable           :: cart_to_pure_5(:,:)
#else
 type transform
   real(dp),allocatable         :: matrix(:,:)
 end type
 integer,parameter :: lmax_transform=3
 type(transform)   :: cart_to_pure(0:lmax_transform)
#endif

 type basis_function
   character(len=100)           :: basis_name
   integer                      :: gaussian_type              ! CARTESIAN or PURE
   integer                      :: shell_index
   integer                      :: am
   character(len=1)             :: amc
   integer                      :: nx,ny,nz
   integer                      :: mm
   real(dp)                     :: x0(3)
   integer                      :: ngaussian
   type(gaussian),allocatable   :: g(:) 
   real(dp),allocatable         :: coeff(:)
 end type

 !
 ! A basis set is a list of basis functions
 ! filtering of some elements can be done by rotation 
 type basis_set
   !
   ! The list
   integer                                 :: nbf
   integer                                 :: nbf_cart
   integer                                 :: gaussian_type              ! CARTESIAN or PURE
   type(basis_function),pointer            :: bf(:) 
   !
   ! then additional data needed for product basis
   integer                                 :: nbf_filtered
   integer,allocatable                     :: index_ij(:,:)
   real(dp),allocatable                    :: rotation(:,:)
 end type basis_set


contains

!=========================================================================
 subroutine init_basis_set(print_volume,basis_name,gaussian_type,basis)
 implicit none
 integer,intent(in)            :: print_volume
 integer,intent(in)            :: gaussian_type
 character(len=100),intent(in) :: basis_name
 type(basis_set),intent(out)   :: basis
!====
 character(len=100)            :: basis_filename
 integer                       :: ibf,jbf,kbf,ng,ig,shell_index
 real(dp),allocatable          :: alpha(:),coeff(:),coeff2(:)
 logical                       :: file_exists
 integer,parameter             :: basis_file=11
 integer                       :: am_tmp,mm,nbf
 logical,parameter             :: normalized=.TRUE.
 integer                       :: iatom
 real(dp)                      :: x0(3)
!====

 basis%nbf           = 0
 basis%nbf_cart      = 0
 basis%gaussian_type = gaussian_type

 !
 ! LOOP OVER ATOMS
 ! TODO could be reduced to the type of atoms in the future
 !
 do iatom=1,natom

   WRITE_MASTER(*,*)
   WRITE_MASTER(*,*) 'Element used for Z value:    ',TRIM(element_name(zatom(iatom)))
   WRITE_MASTER(*,*) 'Element used for the basis:  ',TRIM(element_name(REAL(basis_element(iatom),dp)))
   WRITE_MASTER(*,*) 'Basis type: ',TRIM(basis_name)
   basis_filename=TRIM(element_name(REAL(basis_element(iatom),dp)))//'_'//TRIM(basis_name)
   msg='basis file used: '//basis_filename
   call issue_warning(msg)
  
   WRITE_MASTER(*,*)
   WRITE_MASTER(*,*) 'open the basis set file ',TRIM(basis_filename)
   inquire(file=TRIM(basis_filename),exist=file_exists)
   if(.NOT.file_exists) stop'basis set file not found'
  
   !
   ! read first to get all the dimensions
   open(unit=basis_file,file=TRIM(basis_filename),status='old')
   read(basis_file,*) nbf
   if(nbf<1) stop'ERROR in basis set file'
   do ibf=1,nbf
     read(basis_file,*) ng,am_tmp
     if(ng<1) stop'ERROR in basis set file'
     basis%nbf_cart = basis%nbf_cart + number_basis_function_am(CARTESIAN          ,am_tmp)
     basis%nbf      = basis%nbf      + number_basis_function_am(basis%gaussian_type,am_tmp)
     do ig=1,ng
       read(basis_file,*) 
     enddo
   enddo
   close(basis_file)
  
 enddo

 WRITE_MASTER(*,*)
 WRITE_MASTER(*,*) 'Total number of basis functions',basis%nbf
 if(basis%gaussian_type==PURE) then
   WRITE_MASTER(*,*) 'Total number of cartesian functions',basis%nbf_cart
 endif
 WRITE_MASTER(*,*)
 allocate(basis%bf(basis%nbf_cart))

 jbf         = 0
 shell_index = 0
 do iatom=1,natom

   basis_filename=TRIM(element_name(REAL(basis_element(iatom),dp)))//'_'//TRIM(basis_name)
   open(unit=basis_file,file=TRIM(basis_filename),status='old')
   read(basis_file,*) nbf
   do ibf=1,nbf
     read(basis_file,*) ng,am_tmp
     allocate(alpha(ng),coeff(ng),coeff2(ng))
  
     if(am_tmp<10) then
       do ig=1,ng
         read(basis_file,*) alpha(ig),coeff(ig)
       enddo
     else
       do ig=1,ng
         read(basis_file,*) alpha(ig),coeff(ig),coeff2(ig)
       enddo
     endif
  
     ! rescale the gaussian decay rate whenever zatom /= basis_element
     if( abs( zatom(iatom) - REAL(basis_element(iatom),dp) ) > 1.d-6 ) then
       alpha(:) = alpha(:) * ( zatom(iatom) / REAL(basis_element(iatom),dp) )**2
       WRITE_MASTER(*,*) 'rescaling momentum',am_tmp
       WRITE_MASTER(*,*) 'smallest rescaled alpha:',MINVAL(alpha(:))
     endif
  
     x0(:) = x(:,iatom)

     shell_index = shell_index + 1
  
     select case(am_tmp)
     case( 0)
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,0,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
     case( 1)
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,0,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,1,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,0,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
     case( 2)
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,0,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,1,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,0,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,2,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,1,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,0,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
     case( 3)
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,0,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,1,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,0,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,2,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,1,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,0,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,3,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,2,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,1,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,0,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
     case( 4)
       jbf=jbf+1 ; call init_basis_function(normalized,ng,4,0,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,1,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,0,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,2,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,1,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,0,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,3,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,2,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,1,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,0,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,4,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,3,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,2,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,1,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,0,4,x0,alpha,coeff,shell_index,basis%bf(jbf))
     case( 5)
       jbf=jbf+1 ; call init_basis_function(normalized,ng,5,0,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,4,1,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,4,0,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,2,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,1,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,0,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,3,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,2,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,1,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,0,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,4,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,3,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,2,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,1,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,0,4,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,5,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,4,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,3,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,2,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,1,4,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,0,5,x0,alpha,coeff,shell_index,basis%bf(jbf))
     case( 6)
       jbf=jbf+1 ; call init_basis_function(normalized,ng,6,0,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,5,1,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,5,0,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,4,2,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,4,1,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,4,0,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,3,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,2,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,1,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,0,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,4,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,3,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,2,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,1,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,0,4,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,5,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,4,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,3,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,2,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,1,4,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,0,5,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,6,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,5,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,4,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,3,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,2,4,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,1,5,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,0,6,x0,alpha,coeff,shell_index,basis%bf(jbf))
     case( 7)
       jbf=jbf+1 ; call init_basis_function(normalized,ng,7,0,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,6,1,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,6,0,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,5,2,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,5,1,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,5,0,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,4,3,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,4,2,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,4,1,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,4,0,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,4,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,3,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,2,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,1,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,3,0,4,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,5,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,4,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,3,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,2,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,1,4,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,2,0,5,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,6,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,5,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,4,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,3,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,2,4,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,1,5,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,0,6,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,7,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,6,1,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,5,2,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,4,3,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,3,4,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,2,5,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,1,6,x0,alpha,coeff,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,0,7,x0,alpha,coeff,shell_index,basis%bf(jbf))
     case(10)
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,0,0,x0,alpha,coeff,shell_index,basis%bf(jbf))
       shell_index = shell_index + 1
       jbf=jbf+1 ; call init_basis_function(normalized,ng,1,0,0,x0,alpha,coeff2,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,1,0,x0,alpha,coeff2,shell_index,basis%bf(jbf))
       jbf=jbf+1 ; call init_basis_function(normalized,ng,0,0,1,x0,alpha,coeff2,shell_index,basis%bf(jbf))
     case default
       stop'not implemented'
     end select
  
     deallocate(alpha,coeff,coeff2)
   enddo
   close(basis_file)

 !
 ! END OF THE LOOP OVER ATOMS
 enddo
 

 !
 ! finally output the basis set upon request
 if(MODULO(print_volume/10,2)>0) then
   do ibf=1,basis%nbf
     WRITE_MASTER(*,*) ' Cartesian function number',ibf
     call print_basis_function(basis%bf(ibf))
   enddo
 endif

 WRITE_MASTER(*,*) 'Basis set is ready and fit'

 end subroutine init_basis_set

!=========================================================================
 subroutine init_product_basis_set(basis,prod_basis)
 implicit none
 type(basis_set),intent(in)     :: basis
 type(basis_set),intent(out)    :: prod_basis
!====
 integer                        :: ibf,jbf,iprodbf,jprodbf
 real(dp)                       :: overlap_tmp,norm_tmp
 real(dp),allocatable           :: s_matrix(:,:),eigval(:),eigvec(:,:)
 real(dp),allocatable           :: rotation_tmp(:,:),tmp(:)
 character(len=100)             :: title
!====

 prod_basis%nbf = ( basis%nbf * ( basis%nbf + 1 ) ) / 2
 allocate(prod_basis%bf(prod_basis%nbf))
 allocate(prod_basis%index_ij(2,prod_basis%nbf))

 !
 ! Construct all products
 iprodbf = 0
 do jbf=1,basis%nbf
   do ibf=1,jbf
     iprodbf = iprodbf + 1
     prod_basis%index_ij(1,iprodbf) = ibf
     prod_basis%index_ij(2,iprodbf) = jbf
     call basis_function_prod(basis%bf(ibf),basis%bf(jbf),prod_basis%bf(iprodbf)) 
   enddo
 enddo


#ifdef AUXIL_BASIS
 allocate(s_matrix(prod_basis%nbf,prod_basis%nbf))
 allocate(eigval(prod_basis%nbf))
 allocate(eigvec(prod_basis%nbf,prod_basis%nbf))
 !
 ! first build the full overlap matrix S
 ! in order to identify the most singular eigenvectors
 do jprodbf=1,prod_basis%nbf
   do iprodbf=1,jprodbf  ! the matrix is symmetric S_ab = S_ba
     call overlap_basis_function(prod_basis%bf(iprodbf),prod_basis%bf(jprodbf),overlap_tmp)
     s_matrix(iprodbf,jprodbf) = overlap_tmp
     s_matrix(jprodbf,iprodbf) = overlap_tmp
   enddo
 enddo

 call diagonalize(prod_basis%nbf,s_matrix,eigval,eigvec)


 prod_basis%nbf_filtered = 0
 do iprodbf=1,prod_basis%nbf
   if( eigval(iprodbf) > FILTERED_EIGENVALUE ) prod_basis%nbf_filtered = prod_basis%nbf_filtered + 1
 enddo

 WRITE_MASTER(*,'(a,es12.6)') ' filtering below ',FILTERED_EIGENVALUE
 WRITE_MASTER(*,'(a,i4,a,i4)') ' Conserve ',prod_basis%nbf_filtered,' out of ',prod_basis%nbf

 allocate(prod_basis%rotation(prod_basis%nbf_filtered,prod_basis%nbf))

 jprodbf=0
 do iprodbf=1,prod_basis%nbf
   if( eigval(iprodbf) > FILTERED_EIGENVALUE ) then
     jprodbf=jprodbf+1
     prod_basis%rotation(jprodbf,:) = eigvec(:,iprodbf)    ! THIS HAS BEEN CHECKED ALREADY TWICE! This is correct!
   endif
 enddo

 deallocate(s_matrix,eigval,eigvec)
#endif

 end subroutine init_product_basis_set


!=========================================================================
 subroutine destroy_basis_set(basis)
 implicit none
 type(basis_set),intent(inout) :: basis
!====

 deallocate(basis%bf)
 if(allocated(basis%index_ij)) deallocate(basis%index_ij)
 if(allocated(basis%rotation)) deallocate(basis%rotation)

 end subroutine destroy_basis_set

!=========================================================================
 subroutine init_basis_function(normalized,ng,nx,ny,nz,x0,alpha,coeff,shell_index,bf)
 implicit none
 logical,intent(in)               :: normalized
 integer,intent(in)               :: ng,nx,ny,nz,shell_index
 real(dp),intent(in)              :: x0(3),alpha(ng)
 real(dp),intent(in)              :: coeff(ng)
 type(basis_function),intent(out) :: bf
!====
 integer                          :: ig
 real(dp)                         :: overlap
!====

 bf%ngaussian = ng
 allocate(bf%g(bf%ngaussian))
 allocate(bf%coeff(bf%ngaussian))
 bf%nx    = nx
 bf%ny    = ny
 bf%nz    = nz
 bf%am    = nx + ny + nz
 bf%amc   = orbital_momentum_name(bf%am)
 bf%x0(:) = x0(:)
 bf%shell_index = shell_index

 ! All the gaussians of the contraction have the same orbital momentum
 do ig=1,bf%ngaussian
   call init_gaussian_general(nx,ny,nz,alpha(ig),x0,bf%g(ig))
   bf%coeff(ig) = coeff(ig)
 enddo

 !
 ! check the normalization if requested
 if( normalized ) then
   call overlap_basis_function(bf,bf,overlap)
   if( ABS(overlap-1.0_dp) > 2.0d-5 ) then
     WRITE_MASTER(*,*) 'normalization is different from 1.0',overlap
     WRITE_MASTER(*,*) bf%nx,bf%ny,bf%nz
     WRITE_MASTER(*,*) 'assuming this is a generalized contraction and rescaling coefficients'
     bf%coeff(:) = coeff(:) / SQRT( overlap )
   endif
 endif
 

 end subroutine init_basis_function

!=========================================================================
 subroutine destroy_basis_function(bf)
 implicit none
 type(basis_function),intent(inout) :: bf
!====
 
 deallocate(bf%g,bf%coeff)

 end subroutine destroy_basis_function

!=========================================================================
 function number_basis_function_am(gaussian_type,am)
 integer,intent(in) :: gaussian_type,am
 integer            :: number_basis_function_am
!=====

 select case(gaussian_type)
 case(CARTESIAN)
   select case(am)
   case(0)
     number_basis_function_am = 1
   case(1)
     number_basis_function_am = 3
   case(2)
     number_basis_function_am = 6
   case(3)
     number_basis_function_am = 10
   case(4)
     number_basis_function_am = 15
   case(5)
     number_basis_function_am = 21
   case(6)
     number_basis_function_am = 28
   case(7)
     number_basis_function_am = 36
   case(10) ! stands for SP orbitals
     number_basis_function_am = 4 
   case default
     stop'number_basis_function_am: not implemented'
   end select
 case(PURE)
   if(am/=10) then
     number_basis_function_am = 2 * am + 1
   else ! stands for SP orbitals
     number_basis_function_am = 4 
   endif
 end select

 end function number_basis_function_am

!=========================================================================
 subroutine print_basis_function(bf)
 implicit none
 type(basis_function),intent(in) :: bf
!====
 integer :: ig
!====

 WRITE_MASTER(*,*)
 WRITE_MASTER(*,*) '======  print out a basis function ======'
 WRITE_MASTER(*,'(a30,2x,1(x,i3))')           'contraction of N gaussians',bf%ngaussian
 WRITE_MASTER(*,'(a30,5x,a1)')                'orbital momentum',bf%amc
 WRITE_MASTER(*,'(a30,x,3(f12.6,2x))')        'centered in',bf%x0(:)
 do ig=1,bf%ngaussian
   WRITE_MASTER(*,'(a30,2x,x,i3,2x,f12.6)')   'coefficient',ig,bf%coeff(ig)
 enddo
 WRITE_MASTER(*,*)
 do ig=1,bf%ngaussian
   call print_gaussian(bf%g(ig))
 enddo
 WRITE_MASTER(*,*) '====== end of basis function ======'
 WRITE_MASTER(*,*)

 end subroutine print_basis_function

!=========================================================================
 function eval_basis_function(bf,x)
 implicit none
 type(basis_function),intent(in) :: bf
 real(dp),intent(in)             :: x(3)
 real(dp)                        :: eval_basis_function
!====
 integer                         :: ig
!====

 eval_basis_function=0.0_dp
 do ig=1,bf%ngaussian
   eval_basis_function = eval_basis_function + eval_gaussian(bf%g(ig),x) * bf%coeff(ig)
 enddo

 end function eval_basis_function

!=========================================================================
 function eval_basis_function_grad(bf,x)
 implicit none
 type(basis_function),intent(in) :: bf
 real(dp),intent(in)             :: x(3)
 real(dp)                        :: eval_basis_function_grad(3)
!====
 integer                         :: ig
!====

 eval_basis_function_grad(:)=0.0_dp
 do ig=1,bf%ngaussian
   eval_basis_function_grad(:) = eval_basis_function_grad(:) + eval_gaussian_grad(bf%g(ig),x) * bf%coeff(ig)
 enddo

 end function eval_basis_function_grad

!=========================================================================
 function eval_basis_function_lapl(bf,x)
 implicit none
 type(basis_function),intent(in) :: bf
 real(dp),intent(in)             :: x(3)
 real(dp)                        :: eval_basis_function_lapl(3)
!====
 integer                         :: ig
!====

 eval_basis_function_lapl(:)=0.0_dp
 do ig=1,bf%ngaussian
   eval_basis_function_lapl(:) = eval_basis_function_lapl(:) + eval_gaussian_lapl(bf%g(ig),x) * bf%coeff(ig)
 enddo

 end function eval_basis_function_lapl

!=========================================================================
 subroutine overlap_basis_function(bf1,bf2,overlap)
 implicit none
 type(basis_function),intent(in) :: bf1,bf2
 real(dp),intent(out)            :: overlap
!====
 integer                         :: ig,jg
 real(dp)                        :: overlap_one_gaussian
!====

 overlap=0.0_dp
 do ig=1,bf1%ngaussian
   do jg=1,bf2%ngaussian
#ifdef ATOM
     call overlap_normalized(bf1%g(ig),bf2%g(jg),overlap_one_gaussian)
#else
     call overlap_recurrence(bf1%g(ig),bf2%g(jg),overlap_one_gaussian)
#endif
     overlap = overlap + overlap_one_gaussian * bf1%coeff(ig) * bf2%coeff(jg)
   enddo
 enddo


 end subroutine overlap_basis_function

!=========================================================================
 subroutine overlap_three_basis_function(bf1,bf2,bf3,overlap)
 implicit none
 type(basis_function),intent(in) :: bf1,bf2,bf3
 real(dp),intent(out)            :: overlap
!====
 type(basis_function)            :: bf12
 integer                         :: ig,jg
 real(dp)                        :: overlap_one_gaussian
!====

 if(mod(bf1%nx+bf2%nx+bf3%nx,2)==1) then
   overlap=0.0_dp
   return
 endif
 if(mod(bf1%ny+bf2%ny+bf3%ny,2)==1) then
   overlap=0.0_dp
   return
 endif
 if(mod(bf1%nz+bf2%nz+bf3%nz,2)==1) then
   overlap=0.0_dp
   return
 endif
 !
 ! first multiply the two first basis functions
 call basis_function_prod(bf1,bf2,bf12)

 !
 ! then overlap the product and the third basis function
 call overlap_basis_function(bf12,bf3,overlap)

 !
 ! don't forget to destroy it, else memory is leaking
 call destroy_basis_function(bf12)


 end subroutine overlap_three_basis_function


!=========================================================================
 subroutine kinetic_basis_function(bf1,bf2,kinetic)
 implicit none
 type(basis_function),intent(in) :: bf1,bf2
 real(dp),intent(out)            :: kinetic
!====
 integer                         :: ig,jg
 real(dp)                        :: kinetic_one_gaussian
!====

 kinetic=0.0_dp
 do ig=1,bf1%ngaussian
   do jg=1,bf2%ngaussian
#ifdef ATOM
     call kinetic_gaussian(bf1%g(ig),bf2%g(jg),kinetic_one_gaussian)
#else
     call kinetic_recurrence(bf1%g(ig),bf2%g(jg),kinetic_one_gaussian)
#endif
     kinetic = kinetic + kinetic_one_gaussian * bf1%coeff(ig) * bf2%coeff(jg)
   enddo
 enddo


 end subroutine kinetic_basis_function

!=========================================================================
 subroutine nucleus_basis_function(bf1,bf2,zatom,x,nucleus_pot)
 implicit none
 type(basis_function),intent(in) :: bf1,bf2
 real(dp),intent(in)             :: zatom,x(3)
 real(dp),intent(out)            :: nucleus_pot
!====
 integer                         :: ig,jg
 real(dp)                        :: nucleus_pot_one_gaussian
!====

 nucleus_pot=0.0_dp
 do ig=1,bf1%ngaussian
   do jg=1,bf2%ngaussian
#ifdef ATOM
     call nucleus_pot_gaussian(bf1%g(ig),bf2%g(jg),zatom,nucleus_pot_one_gaussian)
#else
     call nucleus_recurrence(zatom,x,bf1%g(ig),bf2%g(jg),nucleus_pot_one_gaussian)
#endif
     nucleus_pot = nucleus_pot + nucleus_pot_one_gaussian * bf1%coeff(ig) * bf2%coeff(jg)
   enddo
 enddo


 end subroutine nucleus_basis_function

!=========================================================================
 subroutine basis_function_prod(bf1,bf2,bfprod)
 implicit none
 type(basis_function),intent(in)  :: bf1,bf2
 type(basis_function),intent(out) :: bfprod
!====
 integer                         :: ig,jg,kg,ng
 real(dp),allocatable            :: coeff(:),alpha(:)
 logical,parameter               :: unnormalized=.FALSE.
 real(dp)                        :: x0_dummy(3)
!====

 !
 ! one could save some primitive gaussians in case of bf1 * bf1
 ! however it is a very small gain
 ng = bf1%ngaussian * bf2%ngaussian
 allocate(coeff(ng),alpha(ng))
 kg=0
 do ig=1,bf1%ngaussian
   do jg=1,bf2%ngaussian
     kg = kg + 1
     alpha(kg) = bf1%g(ig)%alpha + bf2%g(jg)%alpha
     coeff(kg) = bf1%coeff(ig) * bf2%coeff(jg) *  bf1%g(ig)%norm_factor * bf2%g(jg)%norm_factor 
   enddo
 enddo

 call init_basis_function(unnormalized,ng,bf1%nx+bf2%nx,bf1%ny+bf2%ny,bf1%nz+bf2%nz,x0_dummy,alpha,coeff,1,bfprod)

 !
 ! override the normalization
 ! the product gaussians are UNnormalized
 ! consistently with the ERI basis
 bfprod%g(:)%norm_factor = 1.0_dp

 deallocate(coeff,alpha)

 end subroutine basis_function_prod

!=========================================================================
subroutine basis_function_dipole(bf1,bf2,dipole)
 implicit none
 type(basis_function),intent(in)  :: bf1,bf2
 real(dp),intent(out)             :: dipole(3)
!====
 type(basis_function)             :: bftmp
 real(dp)                         :: dipole_tmp
 integer                          :: ig
 logical,parameter                :: normalized=.FALSE.
!====

 ! 
 ! Calculate < phi_1 | r | phi_2 >
 ! using r = ( r - B ) + B
 !

 ! first set up | (x-xB) phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx+1,bf2%ny,bf2%nz,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor
 ! then overlap < phi1 | (x-xB) phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(1) = dipole_tmp
 ! first set up | xB phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx,bf2%ny,bf2%nz,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor 
 ! then overlap < phi1 | xB phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(1) = dipole(1) + dipole_tmp * bf2%x0(1)

 ! first set up | (y-yB) phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx,bf2%ny+1,bf2%nz,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor
 ! then overlap < phi1 | (y-yB) phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(2) = dipole_tmp
 ! first set up | yB phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx,bf2%ny,bf2%nz,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor 
 ! then overlap < phi1 | yB phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(2) = dipole(2) + dipole_tmp * bf2%x0(2)

 ! first set up | (z-zB) phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx,bf2%ny,bf2%nz+1,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor
 ! then overlap < phi1 | (z-zB) phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(3) = dipole_tmp
 ! first set up | zB phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx,bf2%ny,bf2%nz,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor 
 ! then overlap < phi1 | zB phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(3) = dipole(3) + dipole_tmp * bf2%x0(3)


end subroutine basis_function_dipole


!=========================================================================
subroutine basis_function_dipole_sq(bf1,bf2,dipole)
 implicit none
 type(basis_function),intent(in)  :: bf1,bf2
 real(dp),intent(out)             :: dipole(3)
!====
 type(basis_function)             :: bftmp
 real(dp)                         :: dipole_tmp
 integer                          :: ig
 logical,parameter                :: normalized=.FALSE.
!====

 ! 
 ! Calculate < phi_1 | r^2 | phi_2 >
 ! using r^2 = ( r - B )^2 + 2 B ( r - B ) + B^2
 !

 ! first set up | (x-xB)^2 phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx+2,bf2%ny,bf2%nz,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor
 ! then overlap < phi1 | (x-xB)^2 phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(1) = dipole_tmp

 ! first set up | 2B*(x-xB) phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx+1,bf2%ny,bf2%nz,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor
 ! then overlap < phi1 | 2B*(x-xB) phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(1) = dipole(1) + dipole_tmp * 2.0_dp * bf2%x0(1)

 ! first set up | xB phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx,bf2%ny,bf2%nz,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor 
 ! then overlap < phi1 | xB phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(1) = dipole(1) + dipole_tmp * bf2%x0(1)**2



 ! first set up | (y-yB)^2 phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx,bf2%ny+2,bf2%nz,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor
 ! then overlap < phi1 | (y-yB)^2 phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(2) = dipole_tmp

 ! first set up | 2B*(y-yB) phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx,bf2%ny+1,bf2%nz,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor
 ! then overlap < phi1 | 2B*(y-yB) phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(2) = dipole(2) + dipole_tmp * 2.0_dp * bf2%x0(2)

 ! first set up | yB phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx,bf2%ny,bf2%nz,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor 
 ! then overlap < phi1 | yB phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(2) = dipole(2) + dipole_tmp * bf2%x0(2)**2



 ! first set up | (z-zB)^2 phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx,bf2%ny,bf2%nz+2,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor
 ! then overlap < phi1 | (z-zB)^2 phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(3) = dipole_tmp

 ! first set up | 2B*(z-zB) phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx,bf2%ny,bf2%nz+1,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor
 ! then overlap < phi1 | 2B*(z-zB) phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(3) = dipole(3) + dipole_tmp * 2.0_dp * bf2%x0(3)

 ! first set up | zB phi_2 >
 call init_basis_function(normalized,bf2%ngaussian,bf2%nx,bf2%ny,bf2%nz,bf2%x0,bf2%g(:)%alpha,bf2%coeff,1,bftmp)
 ! override the usual normalization
 bftmp%g(:)%norm_factor = bf2%g(:)%norm_factor 
 ! then overlap < phi1 | zB phi2 >
 call overlap_basis_function(bf1,bftmp,dipole_tmp)
 dipole(3) = dipole(3) + dipole_tmp * bf2%x0(3)**2

end subroutine basis_function_dipole_sq

!=========================================================================
subroutine setup_cart_to_pure_transforms(basis)
 implicit none
 type(basis_set),intent(in) :: basis
!====
 integer  :: il,ni,ii
 integer  :: ibf,jbf
 integer  :: ammax
!====

 WRITE_MASTER(*,*) 'Setting up the cartesian to pure transforms'
 ! Find the maximum angular momentum employed in the calculation
 ammax=-1
 do ibf=1,basis%nbf
   ammax = MAX(ammax,basis%bf(ibf)%am)
 enddo
 WRITE_MASTER(*,'(a50,i3)') 'Maximum angular momentum in the basis set: ',ammax
 WRITE_MASTER(*,'(a50,a3)') '                                           ',orbital_momentum_name(ammax)
 if(ammax > lmax_transform ) then      
   stop'angular momentum too high. Not implemented in cart to pure transform'
 endif


#if 1
 if(basis%gaussian_type == CARTESIAN) then

   do il=0,lmax_transform
     ni = number_basis_function_am(CARTESIAN,il)
     allocate(cart_to_pure(il)%matrix(ni,ni))
     cart_to_pure(il)%matrix(:,:) = 0.0_dp
     do ii=1,ni
       cart_to_pure(il)%matrix(ii,ii) = 1.0_dp
     enddo
   enddo

 else
   ! Formula were read from Ref. 
   ! H.B. Schlegel and M.J. Frisch, INTERNATIONAL JOURNAL OF QUANTUM CHEMISTRY  54, 83-87 (1995).
  
   !
   ! Transform for momentum S
   allocate(cart_to_pure(0)%matrix(1,1))
   cart_to_pure(0)%matrix(1,1) = 1.0_dp
  
   !
   ! Transform for momentum P
   allocate(cart_to_pure(1)%matrix(3,3))
   cart_to_pure(1)%matrix(:,:) = 0.0_dp
   cart_to_pure(1)%matrix(3,2) = 1.0_dp
   cart_to_pure(1)%matrix(1,3) = 1.0_dp
   cart_to_pure(1)%matrix(2,1) = 1.0_dp
  
   !
   ! Transform for momentum D
   allocate(cart_to_pure(2)%matrix(6,5))
   cart_to_pure(2)%matrix(:,:) =  0.0_dp
  
   cart_to_pure(2)%matrix(2,1) =  1.0_dp
  
   cart_to_pure(2)%matrix(5,2) =  1.0_dp
  
   cart_to_pure(2)%matrix(6,3) =  1.0_dp
   cart_to_pure(2)%matrix(1,3) = -0.5_dp
   cart_to_pure(2)%matrix(4,3) = -0.5_dp
  
   cart_to_pure(2)%matrix(3,4) =  1.0_dp
  
   cart_to_pure(2)%matrix(1,5) =  SQRT(3.0/4.0)
   cart_to_pure(2)%matrix(4,5) = -SQRT(3.0/4.0)
  
   !
   ! Transform for momentum F
   allocate(cart_to_pure(3)%matrix(10,7))
   cart_to_pure(3)%matrix( :,:) =  0.0_dp
  
   cart_to_pure(3)%matrix(10,4) =  1.0_dp
   cart_to_pure(3)%matrix( 3,4) = -3.0/(2.0*SQRT(5.0))
   cart_to_pure(3)%matrix( 8,4) = -3.0/(2.0*SQRT(5.0))
  
   cart_to_pure(3)%matrix( 6,5) =  SQRT(6.0/5.0)
   cart_to_pure(3)%matrix( 1,5) = -SQRT(6.0)/4.0
   cart_to_pure(3)%matrix( 4,5) = -SQRT(6.0/5.0)/4.0
  
   cart_to_pure(3)%matrix( 9,3) =  SQRT(6.0/5.0)
   cart_to_pure(3)%matrix( 7,3) = -SQRT(6.0)/4.0
   cart_to_pure(3)%matrix( 2,3) = -SQRT(6.0/5.0)/4.0
  
   cart_to_pure(3)%matrix( 3,6) =  SQRT(3.0/4.0)
   cart_to_pure(3)%matrix( 8,6) = -SQRT(3.0/4.0)
  
   cart_to_pure(3)%matrix( 5,2) = -1.0_dp
  
   cart_to_pure(3)%matrix( 1,7) =  SQRT(10.0)/4.0
   cart_to_pure(3)%matrix( 4,7) = -SQRT(2.0)*3.0/4.0
  
   cart_to_pure(3)%matrix( 7,1) = -SQRT(10.0)/4.0
   cart_to_pure(3)%matrix( 2,1) =  SQRT(2.0)*3.0/4.0
 endif

#else
 !
 ! Transform for momentum S
 allocate(cart_to_pure_0(1,1))
 cart_to_pure_0(1,1) = 1.0_dp

 !
 ! Transform for momentum P
 allocate(cart_to_pure_1(3,3))
 cart_to_pure_1(:,:) = 0.0_dp
 cart_to_pure_1(3,2) = 1.0_dp
 cart_to_pure_1(1,3) = 1.0_dp
 cart_to_pure_1(2,1) = 1.0_dp

 !
 ! Transform for momentum D
 allocate(cart_to_pure_2(6,5))
 cart_to_pure_2(:,:) =  0.0_dp

 cart_to_pure_2(2,1) =  1.0_dp

 cart_to_pure_2(5,2) =  1.0_dp

 cart_to_pure_2(6,3) =  1.0_dp
 cart_to_pure_2(1,3) = -0.5_dp
 cart_to_pure_2(4,3) = -0.5_dp

 cart_to_pure_2(3,4) =  1.0_dp

 cart_to_pure_2(1,5) =  SQRT(3.0/4.0)
 cart_to_pure_2(4,5) = -SQRT(3.0/4.0)

 !
 ! Transform for momentum F
 allocate(cart_to_pure_3(10,7))
 cart_to_pure_3( :,:) =  0.0_dp

 cart_to_pure_3(10,4) =  1.0_dp
 cart_to_pure_3( 3,4) = -3.0/(2.0*SQRT(5.0))
 cart_to_pure_3( 8,4) = -3.0/(2.0*SQRT(5.0))

 cart_to_pure_3( 6,5) =  SQRT(6.0/5.0)
 cart_to_pure_3( 1,5) = -SQRT(6.0)/4.0
 cart_to_pure_3( 4,5) = -SQRT(6.0/5.0)/4.0

 cart_to_pure_3( 9,3) =  SQRT(6.0/5.0)
 cart_to_pure_3( 7,3) = -SQRT(6.0)/4.0
 cart_to_pure_3( 2,3) = -SQRT(6.0/5.0)/4.0

 cart_to_pure_3( 3,6) =  SQRT(3.0/4.0)
 cart_to_pure_3( 8,6) = -SQRT(3.0/4.0)

 cart_to_pure_3( 5,2) = -1.0_dp

 cart_to_pure_3( 1,7) =  SQRT(10.0)/4.0
 cart_to_pure_3( 4,7) = -SQRT(2.0)*3.0/4.0

 cart_to_pure_3( 7,1) = -SQRT(10.0)/4.0
 cart_to_pure_3( 2,1) =  SQRT(2.0)*3.0/4.0
#endif


 WRITE_MASTER(*,*) 'Transformations set up completed'
 WRITE_MASTER(*,*) 

end subroutine setup_cart_to_pure_transforms

!=========================================================================
end module m_basis_set
