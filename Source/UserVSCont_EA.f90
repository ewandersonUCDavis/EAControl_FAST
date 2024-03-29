   ! NOTE: This source file contains an example UserVSCont() user-specified
   !       routine for computing variable-speed controlled generator torque
   !       based on a table look-up of LSS speed and LSS torque provided in a
   !       spd_trq.dat input file.  It also contains an example UserGen, which
   !       calls UserVSCont.  These routines were written by Kirk Pierce (KP),
   !       formerly of NREL/NWTC, and now with GE Wind Energy.  Questions
   !       related to the use of these routines should be addressed to Kirk
   !       Pierce.

!=======================================================================
SUBROUTINE UserGen ( HSS_Spd, GBRatio, NumBl, ZTime, DT, GenEff, DelGenTrq, DirRoot, GenTrq, ElecPwr )


   ! This  example UserGen() is used do the same thing as SUBROUTINE
   !   UserVSCont(), so that setting VSContrl to 0 and GenModel o 3 does
   !   the same thing as setting VSContrl to 2.


USE                            Precision


IMPLICIT                       NONE


   ! Passed Variables:

INTEGER(4), INTENT(IN )     :: NumBl                                         ! Number of blades, (-).

REAL(ReKi), INTENT(IN )     :: DelGenTrq                                     ! Pertubation in generator torque used during FAST linearization (zero otherwise), N-m.
REAL(ReKi), INTENT(IN )     :: DT                                            ! Integration time step, sec.
REAL(ReKi), INTENT(OUT)     :: ElecPwr                                       ! Electrical power (account for losses), watts.
REAL(ReKi), INTENT(IN )     :: GBRatio                                       ! Gearbox ratio, (-).
REAL(ReKi), INTENT(IN )     :: GenEff                                        ! Generator efficiency, (-).
REAL(ReKi), INTENT(OUT)     :: GenTrq                                        ! Electrical generator torque, N-m.
REAL(ReKi), INTENT(IN )     :: HSS_Spd                                       ! HSS speed, rad/s.
REAL(ReKi), INTENT(IN )     :: ZTime                                         ! Current simulation time, sec.


CALL ProgAbort ( 'No generator has been modeled in UserGen(). Please choose a different option for GenModel' )

CHARACTER(1024),INTENT(IN ) :: DirRoot                                       ! The name of the root file including the full path to the current working directory.  This may be useful if you want this routine to write a permanent record of what it does to be stored with the simulation results: the results should be stored in a file whose name (including path) is generated by appending any suitable extension to DirRoot.



!CALL UserVSCont ( HSS_Spd, GBRatio, NumBl, ZTime, DT, GenEff, DelGenTrq, DirRoot, GenTrq, ElecPwr )   ! Let's have UserGen() do the same thing as SUBROUTINE UserVSCont().



RETURN
END SUBROUTINE UserGen
!=======================================================================
SUBROUTINE UserVSCont ( HSS_Spd, GBRatio, NumBl, ZTime, DT, GenEff, DelGenTrq, DirRoot, GenTrq, ElecPwr )


   ! Written 2/28/00 by Kirk Pierce for use with FAST.
   ! This subroutine uses a torque vs speed lookup table.
   ! A first order lag of time constant TCONST is applied to the
   ! calculated torque.

   ! Converted to modern Fortran by M. Buhl.
   ! Modified to calculate electrical generator power by J. Jonkman.

   !                1
   !  GenTrq = ----------- TRQ
   !            TCONST*S+1


USE                            NWTC_Library


IMPLICIT                       NONE


   ! Passed Variables:

INTEGER(4), INTENT(IN )      :: NumBl                                        ! Number of blades, (-).

REAL(ReKi), INTENT(IN )     :: DelGenTrq                                     ! Pertubation in generator torque used during FAST linearization (zero otherwise), N-m.
REAL(ReKi), INTENT(IN )     :: DT                                            ! Integration time step, sec.
REAL(ReKi), INTENT(OUT)     :: ElecPwr                                       ! Electrical power (account for losses), watts.
REAL(ReKi), INTENT(IN )     :: GBRatio                                       ! Gearbox ratio, (-).
REAL(ReKi), INTENT(IN )     :: GenEff                                        ! Generator efficiency, (-).
REAL(ReKi), INTENT(OUT)     :: GenTrq                                        ! Electrical generator torque, N-m.
REAL(ReKi), INTENT(IN )     :: HSS_Spd                                       ! HSS speed, rad/s.
REAL(ReKi), INTENT(IN )     :: ZTime                                         ! Current simulation time, sec.

CHARACTER(1024),INTENT(IN ) :: DirRoot                                       ! The name of the root file including the full path to the current working directory.  This may be useful if you want this routine to write a permanent record of what it does to be stored with the simulation results: the results should be stored in a file whose name (including path) is generated by appending any suitable extension to DirRoot.


   ! Local Variables:

REAL(ReKi), SAVE            :: C1
REAL(ReKi), SAVE            :: C2
REAL(ReKi)                  :: DELT
REAL(ReKi), SAVE            :: FRPM    (5) = 0.0                             ! Filtered RPM.
REAL(ReKi), SAVE            :: FTRQ    = 0.0                                 ! Filtered torque, N-m.
REAL(ReKi), SAVE            :: OLTRQ   = 0.0
REAL(ReKi)                  :: OMEGA                                         ! Rotor speed, rad/s.
REAL(ReKi)                  :: RPM
REAL(ReKi), SAVE            :: RPMSCH  (100)
REAL(ReKi), SAVE            :: SMPDT
REAL(ReKi), PARAMETER       :: TCONST  = 0.05                                ! Time constant of first order lag applied to torque
REAL(ReKi), SAVE            :: TLST    = 0.0
REAL(ReKi), SAVE            :: TRQ     = 0.0
REAL(ReKi), SAVE            :: TRQSCH  (100)
REAL(ReKi), SAVE            :: TTRQ    = 0.0

INTEGER(4)                  :: I
INTEGER(4)                  :: IOS                                           ! I/O status.  Negative values indicate end of file.
INTEGER(4)                  :: N1
INTEGER, SAVE               :: NSCH   = 0                                    ! Number of lines found in the file
INTEGER, PARAMETER          :: NST    = 5                                    ! Number of integration time steps between controller torque calculations.
INTEGER, PARAMETER          :: UnCont = 99                                   ! Unit number for the input file

LOGICAL,    SAVE            :: SFLAG  = .TRUE.

CHARACTER(1024)             :: TITLE
CHARACTER(1024)             :: inFileName                                     ! name of the input file


  ! Abort if GBRatio is not unity; since this example routine returns the
  !   generator torque cast to the LSS side of the gearbox, whereas routine
  !   UserVSCont() should be returning the torque on the HSS side:

IF ( GBRatio /= 1.0 )  CALL ProgAbort ( ' GBRatio must be set to 1.0 when using Kirk Pierce''s UserVSCont() routine.' )



OMEGA = HSS_Spd


IF ( SFLAG )  THEN

   I = INDEX( DirRoot, PathSep, BACK=.TRUE. )
   IF ( I < LEN_TRIM(DirRoot) .OR. I > 0 ) THEN
      inFileName = DirRoot(1:I)//'spd_trq.dat'
   ELSE
      inFileName = 'spd_trq.dat'
   END IF


   CALL OpenFInpFile ( UnCont, TRIM(inFileName) )

   READ (UnCont,'(A)') TITLE

   CALL WrScr1( ' Using variable speed generator option.' )
   CALL WrScr ( '   '//TRIM( TITLE ) )
   CALL WrScr ( ' ' )

   DO I=1,100
      READ(UnCont,*,IOSTAT=IOS)  RPMSCH(I), TRQSCH(I)
      IF ( IOS < 0 )  EXIT

      IF ( I > 1 ) THEN
         IF ( RPMSCH(I) <= RPMSCH(I-1) ) THEN
            CALL ProgWarn('RPM schedule must be increasing in file spd_trq.dat. Schedule will be stopped at ' &
                                   //TRIM(Flt2LStr(RPMSCH(I-1)))//' RPM.')
            EXIT
         END IF
      END IF
      NSCH = NSCH + 1
   ENDDO ! I

   SMPDT = REAL( NST )*DT

   C1 = EXP( -DT/TCONST )
   C2 = 1.0 - C1

   SFLAG = .FALSE.
   CLOSE(UnCont)

   IF ( NSCH < 2 ) THEN
      IF ( NSCH == 0 ) THEN
         RPMSCH(1) = 0.0
         TRQSCH(1) = 0.0
      END IF
      NSCH = 2
      RPMSCH(2) = RPMSCH(1)
      TRQSCH(2) = TRQSCH(1)
   END IF
ENDIF

DELT = ZTime - TLST


   ! Calculate torque setting at every NST time steps.

IF ( DELT >= ( SMPDT - 0.5*DT ) )  THEN

   TLST = ZTime  !BJJ: TLST is a saved variable, which may have issues on re-initialization.


   ! Update old values.

   DO I=5,2,-1
      FRPM(I) = FRPM(I-1)
   ENDDO ! I

   RPM = OMEGA * 30.0/PI

   ! Calculate recursive lowpass filtered value.

   FRPM(1) = 0.7*FRPM(2) + 0.3*RPM


   FRPM(1) = MIN( MAX( FRPM(1), RPMSCH(1) ), RPMSCH(NSCH) )
   TRQ     = InterpBin( FRPM(1), RPMSCH(1:NSCH), TRQSCH(1:NSCH), N1, NSCH )


ENDIF


   ! Torque is updated at every integrator time step

IF ( ZTime > TTRQ )  THEN

   FTRQ  = C1*FTRQ + C2*OLTRQ
   OLTRQ = TRQ
   TTRQ  = ZTime + 0.5*DT

ENDIF


GenTrq = FTRQ + DelGenTrq  ! Make sure to add the pertubation on generator torque, DelGenTrq.  This is used only for FAST linearization (it is zero otherwise).

   ! The generator efficiency is either additive for motoring,
   !   or subtractive for generating power.

IF ( GenTrq > 0.0 )  THEN
   ElecPwr = GenTrq*HSS_Spd*GenEff
ELSE
   ElecPwr = GenTrq*HSS_Spd/GenEff
ENDIF



RETURN
END SUBROUTINE UserVSCont
!=======================================================================
