function [ LogObservationLikelihood, xnn, Ssnn, deltasnn, taunn, nunn, wnn, Pnn, deltann, xno, Psno, deltasno, tauno, nuno ] = ...
    KalmanStep( m, xoo, Ssoo, deltasoo, tauoo, nuoo, RootExoVar, diagLambda, nuno, MParams, OoDrYs, dynareOBC, LagIndices, CurrentIndices, FutureValues, SelectAugStateVariables )

    LogObservationLikelihood = NaN;
    xnn = [];
    Ssnn = [];
    deltasnn = [];
    taunn = [];
    nunn = [];
    wnn = [];
    Pnn = [];
    deltann = [];
    xno = [];
    Psno = [];
    deltasno = [];
    tauno = [];
    
    NAugState1 = size( Ssoo, 1 );
    NAugState2 = size( Ssoo, 2 );
    NExo1 = size( RootExoVar, 1 );
    NExo2 = size( RootExoVar, 2 );
    
    IntDim = NAugState2 + NExo2 + 2;
    
    if isfinite( nuoo )
        if dynareOBC.FilterCubatureDegree > 0
            CubatureOrder = ceil( 0.5 * ( dynareOBC.FilterCubatureDegree - 1 ) );
            [ CubatureWeights, pTmp, NCubaturePoints ] = fwtpts( IntDim, CubatureOrder );
        else
            NCubaturePoints = 2 * IntDim + 1;
            wTemp = 0.5 * sqrt( 2 * NCubaturePoints );
            pTmp = [ zeros( IntDim, 1 ), wTemp * eye( IntDim ), -wTemp * eye( IntDim ) ];
            CubatureWeights = 1 / NCubaturePoints;
        end

        PhiN10 = normcdf( pTmp( end, : ) );
        FInvScaledInvChi = sqrt( 0.5 * ( nuoo + 1 ) ./ gammaincinv( PhiN10, 0.5 * ( nuoo + 1 ), 'upper' ) );
        FInvScaledInvChi( ~isfinite( FInvScaledInvChi ) ) = 1;
    end
    
    if ~isfinite( nuoo ) || all( abs( FInvScaledInvChi - 1 ) <= sqrt( eps ) )
        IntDim = NAugState2 + NExo2 + 1;

        if dynareOBC.FilterCubatureDegree > 0
            [ CubatureWeights, pTmp, NCubaturePoints ] = fwtpts( IntDim, CubatureOrder );
        else
            NCubaturePoints = 2 * IntDim + 1;
            wTemp = 0.5 * sqrt( 2 * NCubaturePoints );
            pTmp = [ zeros( IntDim, 1 ), wTemp * eye( IntDim ), -wTemp * eye( IntDim ) ];
            CubatureWeights = 1 / NCubaturePoints;
        end

        FInvScaledInvChi = ones( NCubaturePoints, 1 );
    else
        pTmp( end, : ) = [];
    end

    PhiN0 = normcdf( pTmp( end, : ) );
    pTmp( end, : ) = [];
    
    tcdf_tauoo_nuoo = tcdf( tauoo, nuoo );
    FInvEST = tinv( 1 - ( 1 - PhiN0 ) * tcdf_tauoo_nuoo, nuoo );
    N11Scaler = FInvScaledInvChi .* sqrt( ( nu + FInvEST .^ 2 ) / ( 1 + nu ) );
    
    CubaturePoints = bsxfun( @plus, [ Ssoo * bsxfun( @times, pTmp( 1:NAugState2,: ), N11Scaler ) + bsxfun( @times, deltasoo, FInvEST ); RootExoVar * pTmp( (NAugState2+1):end,: ) ], [ xoo; zeros( NExo1, 1 ) ] );
    
    Constant = dynareOBC.Constant;
    NEndo = length( Constant );
    NEndoMult = 2 .^ ( dynareOBC.Order - 1 );
    
    NAugEndo = NEndo * NEndoMult;

    StatePoints = CubaturePoints( 1:NAugState1, : );
    ExoPoints = CubaturePoints( (NAugState1+1):(NAugState1+NExo1), : );

    OldAugEndoPoints = zeros( NAugEndo, NCubaturePoints );
    OldAugEndoPoints( SelectAugStateVariables, : ) = StatePoints;
    
    Observed = find( isfinite( m ) );
    FiniteMeasurements = m( Observed )';
    NObs = length( Observed );
       
    NewAugEndoPoints = zeros( NAugEndo, NCubaturePoints );
    
    for i = 1 : NCubaturePoints
        InitialFullState = GetFullStateStruct( OldAugEndoPoints( :, i ), dynareOBC.Order, Constant );
        try
            Simulation = SimulateModel( ExoPoints( :, i ), false, InitialFullState, true, true );
        catch
            return
        end
        
        if dynareOBC.Order == 1
            NewAugEndoPoints( :, i ) = Simulation.first + Simulation.bound_offset;
        elseif dynareOBC.Order == 2
            NewAugEndoPoints( :, i ) = [ Simulation.first; Simulation.second + Simulation.bound_offset ];
        else
            NewAugEndoPoints( :, i ) = [ Simulation.first; Simulation.second; Simulation.first_sigma_2; Simulation.third + Simulation.bound_offset ];
        end
        if any( ~isfinite( NewAugEndoPoints( :, i ) ) )
            return
        end
    end
    
    if NObs > 0
        LagValuesWithBoundsBig = bsxfun( @plus, reshape( sum( reshape( OldAugEndoPoints, NEndo, NEndoMult, NCubaturePoints ), 2 ), NEndo, NCubaturePoints ), Constant );
        LagValuesWithBoundsLagIndices = LagValuesWithBoundsBig( LagIndices, : );
        
        CurrentValuesWithBoundsBig = bsxfun( @plus, reshape( sum( reshape( NewAugEndoPoints, NEndo, NEndoMult, NCubaturePoints ), 2 ), NEndo, NCubaturePoints ), Constant );
        CurrentValuesWithBoundsCurrentIndices = CurrentValuesWithBoundsBig( CurrentIndices, : );
        
        MLVValues = dynareOBCTempGetMLVs( [ LagValuesWithBoundsLagIndices; CurrentValuesWithBoundsCurrentIndices; repmat( FutureValues, 1, NCubaturePoints ) ], ExoPoints, MParams, OoDrYs );
        NewMeasurementPoints = MLVValues( Observed, : );
        if any( any( ~isfinite( NewMeasurementPoints ) ) )
            return
        end
    else
        NewMeasurementPoints = zeros( 0, NCubaturePoints );
    end

    StdDevThreshold = dynareOBC.StdDevThreshold;

    wm = [ NewAugEndoPoints; ExoPoints; zeros( NObs, NCubaturePoints ); NewMeasurementPoints ];
    
    nwm = size( wm, 1 );
    
    Median_wm = wm( :, 1 );
    
    Mean_wm = sum( bsxfun( @times, wm, CubatureWeights ), 2 );
    ano = bsxfun( @minus, wm, Mean_wm );
    Weighted_ano = bsxfun( @times, ano, CubatureWeights );
    
    Variance_wm = zeros( nwm, nwm );
    ZetaBlock = ( nwm - 2 * NObs + 1 ) : nwm;
    Lambda = diag( diagLambda );
    Variance_wm( ZetaBlock, ZetaBlock ) = [ Lambda, Lambda; Lambda, Lambda ];
    
    Variance_wm = Variance_wm + NearestSPD( ano' * Weighted_ano );
    Variance_wm = 0.5 * ( Variance_wm + Variance_wm' );
    cholVariance_wm = chol( Variance_wm );
    
    Mean_wmMMedian_wm = Mean_wm - Median_wm;
    cholVariance_wm_Mean_wmMMedian_wm = cholVariance_wm * Mean_wmMMedian_wm;
    cholVariance_wm_Mean_wmMMedian_wm2 = cholVariance_wm_Mean_wmMMedian_wm' * cholVariance_wm_Mean_wmMMedian_wm;
    
    if cholVariance_wm_Mean_wmMMedian_wm2 > eps && ~dynareOBC.NoSkewLikelihood
        Zcheck_wm = ( Mean_wmMMedian_wm' * ano ) / sqrt( cholVariance_wm_Mean_wmMMedian_wm2 );

        meanZcheck_wm = Zcheck_wm * CubatureWeights';
        Zcheck_wm = Zcheck_wm - meanZcheck_wm;
        meanZcheck_wm2 = Zcheck_wm.^2 * CubatureWeights';
        Zcheck_wm = Zcheck_wm / sqrt( meanZcheck_wm2 );

        sZ3 = Zcheck_wm.^3 * CubatureWeights';
        sZ4 = Zcheck_wm.^4 * CubatureWeights';

        if isempty( nuno )
            tauno_nuno = lsqnonlin( @( in ) CalibrateMomentsEST( in( 1 ), in( 2 ), Mean_wm, Median_wm, cholVariance_wm, sZ3, sZ4 ), [ tauoo; nuoo ], [ -Inf; 4 + eps( 4 ) ], [], optimoptions( @lsqnonlin, 'display', 'off', 'MaxFunctionEvaluations', Inf, 'MaxIterations', Inf ) );
            tauno = tauno_nuno( 1 );
            nuno = tauno_nuno( 2 );
        else
            tauno = lsqnonlin( @( in ) CalibrateMomentsEST( in( 1 ), nuno, Mean_wm, Median_wm, cholVariance_wm, sZ3, [] ), tauoo, [], [], optimoptions( @lsqnonlin, 'display', 'off', 'MaxFunctionEvaluations', Inf, 'MaxIterations', Inf ) );
        end
    else
        tauno = -Inf;
        
        if isempty( nuno )
            Zcheck_wm = cholVariance_wm * ano;

            meanZcheck_wm = Zcheck_wm * CubatureWeights';
            Zcheck_wm = bsxfun( @minus, Zcheck_wm, meanZcheck_wm );
            meanZcheck_wm2 = Zcheck_wm.^2 * CubatureWeights';
            Zcheck_wm = bsxfun( @times, Zcheck_wm, 1 ./ sqrt( meanZcheck_wm2 ) );

            kurtDir = max( 0, Zcheck_wm.^4 * CubatureWeights' - 3 );

            if kurtDir' * kurtDir < eps
                kurtDir = Zcheck_wm.^4 * CubatureWeights';
            end

            kurtDir = kurtDir / norm( kurtDir );

            Zcheck_wm = kurtDir' * Zcheck_wm;

            meanZcheck_wm = Zcheck_wm * CubatureWeights';
            Zcheck_wm = Zcheck_wm - meanZcheck_wm;
            meanZcheck_wm2 = Zcheck_wm.^2 * CubatureWeights';
            Zcheck_wm = Zcheck_wm / sqrt( meanZcheck_wm2 );

            sZ4 = max( 3, Zcheck_wm.^4 * CubatureWeights' );
            nuno = 4 + 6 / ( sZ4 - 3 );
        end
    end

    WBlock = 1 : ( NAugEndo + NExo + NObs );
    PredictedW = Mean_wm( WBlock );                                           % w_{t|t-1} in the paper
    PredictedWVariance = Variance_wm( WBlock, WBlock );                   % V_{t|t-1} in the paper
    
    MBlock = ( nwm - NObs + 1 ) : nwm;
    PredictedM = Mean_wm( MBlock );                                           % m_{t|t-1} in the paper
    PredictedMVariance = Variance_wm( MBlock, MBlock );                   % Q_{t|t-1} in the paper
    PredictedWMCovariance = Variance_wm( WBlock, MBlock );                % R_{t|t-1} in the paper
    
    if dynareOBC.NoSkewLikelihood
        LocationM = PredictedM;
    else
        LocationM = wm( MBlock, 1 );
    end
    
    if NObs > 0
    
        [ ~, InvRootPredictedMVariance, LogDetPredictedMVariance ] = ObtainEstimateRootCovariance( PredictedMVariance, 0 );
        ScaledPredictedWMCovariance = PredictedWMCovariance * InvRootPredictedMVariance';
        ScaledResiduals = InvRootPredictedMVariance * ( FiniteMeasurements - PredictedM );

        wnn = PredictedW + ScaledPredictedWMCovariance * ScaledResiduals;                              % w_{t|t} in the paper
        Pnn = PredictedWVariance - ScaledPredictedWMCovariance * ScaledPredictedWMCovariance'; % V_{t|t} in the paper

        xnn = wnn( SelectAugStateVariables );                                                     % x_{t|t} in the paper
        UpdatedXVariance = Pnn( SelectAugStateVariables, SelectAugStateVariables );            % P_{t|t} in the paper
    
        LogObservationLikelihood = LogDetPredictedMVariance + ScaledResiduals' * ScaledResiduals + NObs * 1.8378770664093454836;

    else
        
        wnn = PredictedW;
        Pnn = PredictedWVariance;

        xnn = PredictedW( SelectAugStateVariables );
        UpdatedXVariance = PredictedWVariance( SelectAugStateVariables, SelectAugStateVariables );
        
        LogObservationLikelihood = 0;
        
    end
    
    
    if Smoothing
        [ Ssnn, InvRootUpdatedXVariance ] = ObtainEstimateRootCovariance( UpdatedXVariance, StdDevThreshold );
        RootUpdatedWVariance = ObtainEstimateRootCovariance( Pnn, 0 );
        SmootherGain = ( RootOldWVariance * RootOldWVariance( 1:NAugState1, : )' ) * ( InvRootOldXVariance' * InvRootOldXVariance ) * CovOldNewX * ( InvRootUpdatedXVariance' * InvRootUpdatedXVariance ); % B_{t|t-1} * S_{t|t-1}^- in the paper
        xno = PredictedW( SelectAugStateVariables );
        Psno = PredictedWVariance( SelectAugStateVariables, SelectAugStateVariables );
    else
        Ssnn = ObtainEstimateRootCovariance( UpdatedXVariance, StdDevThreshold );
    end
        
end

function FullStateStruct = GetFullStateStruct( CurrentState, Order, Constant )
    NEndo = length( Constant );
    FullStateStruct = struct;
    FullStateStruct.first = CurrentState( 1:NEndo );
    total = FullStateStruct.first + Constant;
    if Order >= 2
        FullStateStruct.second = CurrentState( (NEndo+1):(2*NEndo) );
        total = total + FullStateStruct.second;
        if Order >= 3
            FullStateStruct.first_sigma_2 = CurrentState( (2*NEndo+1):(3*NEndo) );
            FullStateStruct.third = CurrentState( (3*NEndo+1):(4*NEndo) );
            total = total + FullStateStruct.first_sigma_2 + FullStateStruct.third;
        end
    end
    FullStateStruct.bound_offset = zeros( NEndo, 1 );
    FullStateStruct.total = total;
    FullStateStruct.total_with_bounds = FullStateStruct.total;
end
