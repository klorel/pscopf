using PSCOPF

using Test
using JuMP
using Dates
using DataStructures

@testset verbose=true "test_energy_market_start_cost" begin


    #=
    TS: [11h, 11h15]
    S: [S1,S2]
                        bus 1
                        |
    (imposable) prod_1_1|          load_1
    Pmin=10, Pmax=100   |S1: 30     S1: 50
    Csta=45k, Cprop=10  |S2: 25     S2: 35
                        |
    (imposable) prod_1_2|
     Pmin=10, Pmax=100  |
     Csta=80k, Cprop=15 |
    =#

    TS = [DateTime("2015-01-01T11:00:00"), DateTime("2015-01-01T11:15:00")]
    ech = DateTime("2015-01-01T07:00:00")
    network = PSCOPF.Networks.Network()
    # Buses
    PSCOPF.Networks.add_new_bus!(network, "bus_1")
    # Imposables
    PSCOPF.Networks.add_new_generator_to_bus!(network, "bus_1", "prod_1_1", PSCOPF.Networks.IMPOSABLE,
                                            10., 100.,
                                            45000., 10.,
                                            Dates.Second(0), Dates.Second(0))
    PSCOPF.Networks.add_new_generator_to_bus!(network, "bus_1", "prod_1_2", PSCOPF.Networks.IMPOSABLE,
                                            10., 100.,
                                            80000., 15.,
                                            Dates.Second(0), Dates.Second(0))
    # Uncertainties
    uncertainties = PSCOPF.Uncertainties()
    PSCOPF.add_uncertainty!(uncertainties, ech, "bus_1", DateTime("2015-01-01T11:00:00"), "S1", 30.)
    PSCOPF.add_uncertainty!(uncertainties, ech, "bus_1", DateTime("2015-01-01T11:00:00"), "S2", 25.)
    PSCOPF.add_uncertainty!(uncertainties, ech, "bus_1", DateTime("2015-01-01T11:15:00"), "S1", 50.)
    PSCOPF.add_uncertainty!(uncertainties, ech, "bus_1", DateTime("2015-01-01T11:15:00"), "S2", 35.)
    # firmness
    firmness = PSCOPF.Firmness(
                SortedDict("prod_1_1" => SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.FREE,
                                                    Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.FREE),
                            "prod_1_2" => SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.FREE,
                                                    Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.FREE) ),
                SortedDict( "prod_1_1" => SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.FREE,
                                                    Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.FREE),
                            "prod_1_2" => SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.FREE,
                                                    Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.FREE), )
                )

    #=
    prod_1_1 is ON, prod_1_2 is ON
    We only use prod_1_1 cause its prop cost is lower
    =#
    @testset "energy_market_no_starting_cost_if_units_already_started" begin
        # initial generators state
        generators_init_state = SortedDict(
            "prod_1_1" => PSCOPF.ON,
            "prod_1_2" => PSCOPF.ON
        )
        context = PSCOPF.PSCOPFContext(network, TS, PSCOPF.PSCOPF_MODE_1,
                                        generators_init_state,
                                        uncertainties, nothing)
        market = PSCOPF.EnergyMarket()
        result = PSCOPF.run(market, ech, firmness,
                    PSCOPF.get_target_timepoints(context),
                    context)
        PSCOPF.update_market_schedule!(context, ech, result, firmness, market)

        # Solution is optimal
        @test PSCOPF.get_status(result) == PSCOPF.pscopf_OPTIMAL
        @test value(result.objective_model.start_cost) < 1e-09

        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[1], "S1")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[1], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[2], "S1")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[2], "S2")

        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S1")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S2")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S1")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S2")
    end

    #=
    prod_1_1 is OFF, prod_1_2 is ON
    We only use prod_1_2 cause its already started => no start cost => cheaper
    =#
    @testset "energy_market_no_starting_cost_for_unit_prod_1_2" begin
        # initial generators state
        generators_init_state = SortedDict(
            "prod_1_1" => PSCOPF.OFF,
            "prod_1_2" => PSCOPF.ON
        )
        context = PSCOPF.PSCOPFContext(network, TS, PSCOPF.PSCOPF_MODE_1,
                                        generators_init_state,
                                        uncertainties, nothing)
        market = PSCOPF.EnergyMarket()
        result = PSCOPF.run(market, ech, firmness,
                    PSCOPF.get_target_timepoints(context),
                    context)
        PSCOPF.update_market_schedule!(context, ech, result, firmness, market)

        # Solution is optimal
        @test PSCOPF.get_status(result) == PSCOPF.pscopf_OPTIMAL
        @test value(result.objective_model.start_cost) < 1e-09
        #high start cost for prod_1_1 => not used
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[1], "S1")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[1], "S2")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[2], "S1")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[2], "S2")
        #no start cost for prod_1_2 => used eventhough it's unitary prop_cost is higher
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S1")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S1")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S2")
    end

    #=
    prod_1_1 is OFF, prod_1_2 is OFF
    We only use prod_1_1 cause it's cheaper (mainly in terms of start cost)
    =#
    @testset "energy_market_starting_cost" begin
        # initial generators state
        generators_init_state = SortedDict(
            "prod_1_1" => PSCOPF.OFF,
            "prod_1_2" => PSCOPF.OFF
        )
        context = PSCOPF.PSCOPFContext(network, TS, PSCOPF.PSCOPF_MODE_1,
                                        generators_init_state,
                                        uncertainties, nothing)
        market = PSCOPF.EnergyMarket()
        result = PSCOPF.run(market, ech, firmness,
                    PSCOPF.get_target_timepoints(context),
                    context)
        PSCOPF.update_market_schedule!(context, ech, result, firmness, market)

        # Solution is optimal
        @test PSCOPF.get_status(result) == PSCOPF.pscopf_OPTIMAL
        @test 2*45000. ≈ value(result.objective_model.start_cost) # started in 2 scenarios

        #start cost for prod_1_1 prefered to prod_1_2
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[1], "S1")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[1], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[2], "S1")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[2], "S2")
        #higher start cost for prod_1_2 => not used
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S1")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S2")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S1")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S2")
    end

    #=
    TS: [11h, 11h15]
    S: [S1,S2]
                        bus 1
                        |
    (imposable) prod_1_1|          load_1
    Pmin=10, Pmax=100   |S1: 30     S1: 50
    Csta=45k, Cprop=10  |S2: 25     S2: 165
                        |
    (imposable) prod_1_2|
     Pmin=10, Pmax=100  |
     Csta=80k, Cprop=15 |

    We have high demand for TS2, S2
    =#

    #=
    both units are ON
    In TS2,S2, we need both units
    but in TS1 one unit is enough
    => if we turn off a unit in TS1, we will need to restart it for TS2
    => it's cheaper to use both units at TS1 non-optimally to get the global optimum
    =#
    @testset "energy_market_both_units_used_in_S2_to_avoid_restart_cost" begin
        #bus2, S2, TS:11h15 : high demand
        PSCOPF.add_uncertainty!(uncertainties, ech, "bus_1", DateTime("2015-01-01T11:15:00"), "S2", 165.)

        # initial generators state
        generators_init_state = SortedDict(
            "prod_1_1" => PSCOPF.ON,
            "prod_1_2" => PSCOPF.ON
        )
        context = PSCOPF.PSCOPFContext(network, TS, PSCOPF.PSCOPF_MODE_1,
                                        generators_init_state,
                                        uncertainties, nothing)
        market = PSCOPF.EnergyMarket()
        result = PSCOPF.run(market, ech, firmness,
                    PSCOPF.get_target_timepoints(context),
                    context)
        PSCOPF.update_market_schedule!(context, ech, result, firmness, market)

        # Solution is optimal
        @test PSCOPF.get_status(result) == PSCOPF.pscopf_OPTIMAL
        @test value(result.objective_model.start_cost) <= 1e-09 # No start cost, in S2, prod_1_2 is used in TS1 to avoid restart

        #start cost for prod_1_1 prefered to prod_1_2
        @test 30. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_1", TS[1], "S1")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[1], "S1")
        @test 15. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_1", TS[1], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[1], "S2")
        @test 50. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_1", TS[2], "S1")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[2], "S1")
        @test 100. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_1", TS[2], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[2], "S2")
        #higher start cost for prod_1_2 => not used
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S1")
        @test 10. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_2", TS[1], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S2")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S1")
        @test 65. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_2", TS[2], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S2")

        #reset original value
        PSCOPF.add_uncertainty!(uncertainties, ech, "bus_1", DateTime("2015-01-01T11:15:00"), "S2", 65.)
    end

    #=
    both units are OFF
    in TS1 one unit is enough => start prod_1_1
    In TS2,S2, we need both units => start prod_1_2
    =#
    @testset "energy_market_both_units_are_started_when_needed" begin
        #bus2, S2, TS:11h15 : high demand
        PSCOPF.add_uncertainty!(uncertainties, ech, "bus_1", DateTime("2015-01-01T11:15:00"), "S2", 165.)

        # initial generators state
        generators_init_state = SortedDict(
            "prod_1_1" => PSCOPF.OFF,
            "prod_1_2" => PSCOPF.OFF
        )
        context = PSCOPF.PSCOPFContext(network, TS, PSCOPF.PSCOPF_MODE_1,
                                        generators_init_state,
                                        uncertainties, nothing)
        market = PSCOPF.EnergyMarket()
        result = PSCOPF.run(market, ech, firmness,
                    PSCOPF.get_target_timepoints(context),
                    context)
        PSCOPF.update_market_schedule!(context, ech, result, firmness, market)

        # Solution is optimal
        @test PSCOPF.get_status(result) == PSCOPF.pscopf_OPTIMAL
        @test (2*45000 + 80000) ≈ value(result.objective_model.start_cost)  # prod1 started in 2 scenarios, prod2 in S2

        # S1 : prod_1_1 is cheaper to start => used
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[1], "S1")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S1")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[2], "S1")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S1")
        @test 30. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_1", TS[1], "S1")
        @test 50. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_1", TS[2], "S1")
        @test PSCOPF.get_prod_value(context.market_schedule, "prod_1_2", TS[1], "S1") < 1e-09
        @test PSCOPF.get_prod_value(context.market_schedule, "prod_1_2", TS[2], "S1") < 1e-09

        # S2 : prod_1_2 is needed to satisfy demand it also has high proportional cost
        # => prod_1_2 is only started when needed
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[1], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[2], "S2")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S2")
        @test 25. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_1", TS[1], "S2")
        @test 100. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_1", TS[2], "S2")
        @test PSCOPF.get_prod_value(context.market_schedule, "prod_1_2", TS[1], "S2") < 1e-09
        @test 65. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_2", TS[2], "S2")

        #reset original value
        PSCOPF.add_uncertainty!(uncertainties, ech, "bus_1", DateTime("2015-01-01T11:15:00"), "S2", 65.)
    end


    #=
    definitive starting decisions made in
     the tso_schedule and the reference market schedule are gratis for the EnergyMarket
    Here, in tso_schedule, we :
        - consider starting prod_1_1  (non-definitive decision) => it is not gratis for market
        - start prod_1_2 (definitive decision) => prod_1_2 has no start cost for market
    =#
    @testset "energy_market_test_gratis_start" begin
        #bus2, S2, TS:11h15 : high demand
        PSCOPF.add_uncertainty!(uncertainties, ech, "bus_1", DateTime("2015-01-01T11:15:00"), "S2", 165.)

        # initial generators state
        generators_init_state = SortedDict(
            "prod_1_1" => PSCOPF.OFF,
            "prod_1_2" => PSCOPF.OFF
        )
        context = PSCOPF.PSCOPFContext(network, TS, PSCOPF.PSCOPF_MODE_1,
                                        generators_init_state,
                                        uncertainties, nothing)

        context.tso_schedule = PSCOPF.Schedule(PSCOPF.TSO(), Dates.DateTime("2015-01-01T06:00:00"), SortedDict(
                                        "prod_1_1" => PSCOPF.GeneratorSchedule("prod_1_1",
                                            SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.UncertainValue{PSCOPF.GeneratorState}(missing,
                                                                                                                    SortedDict("S1"=>PSCOPF.ON, "S2"=>PSCOPF.ON)),
                                                        Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.UncertainValue{PSCOPF.GeneratorState}(missing,
                                                                                                                    SortedDict("S1"=>PSCOPF.ON, "S2"=>PSCOPF.ON))
                                                        ),
                                            SortedDict{Dates.DateTime, PSCOPF.UncertainValue{Float64}}(),
                                            ),
                                        "prod_1_2" => PSCOPF.GeneratorSchedule("prod_1_2",
                                            SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.UncertainValue{PSCOPF.GeneratorState}(PSCOPF.ON,
                                                                                                                    SortedDict("S1"=>PSCOPF.ON, "S2"=>PSCOPF.ON)),
                                                        Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.UncertainValue{PSCOPF.GeneratorState}(PSCOPF.ON,
                                                                                                                    SortedDict("S1"=>PSCOPF.ON, "S2"=>PSCOPF.ON))
                                                        ),
                                            SortedDict{Dates.DateTime, PSCOPF.UncertainValue{Float64}}(),
                                            )
                                        )
                                )

        market = PSCOPF.EnergyMarket()
        result = PSCOPF.run(market, ech, firmness,
                    PSCOPF.get_target_timepoints(context),
                    context)
        PSCOPF.update_market_schedule!(context, ech, result, firmness, market)

        # Solution is optimal
        @test PSCOPF.get_status(result) == PSCOPF.pscopf_OPTIMAL
        @test (45000) ≈ value(result.objective_model.start_cost)  # prod1 started in 2 scenarios, prod2 in S2
        @test( value(result.objective_model.prop_cost) ≈
              (   (0.   *10. + 30. * 15) #TS1, S1
                + (0.   *10. + 50. * 15) #TS2, S1
                + (15.  *10. + 10.  * 15) #TS1, S2
                + (100. *10. + 65. * 15) #TS2, S2
              )
        )

        #S1 : need one generator, prod_1_2 can be started gratis => no need to start prod_1_1
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[1], "S1")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S1")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[2], "S1")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S1")
        @test PSCOPF.get_prod_value(context.market_schedule, "prod_1_1", TS[1], "S1") < 1e-09
        @test PSCOPF.get_prod_value(context.market_schedule, "prod_1_1", TS[2], "S1") < 1e-09
        @test 30. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_2", TS[1], "S1")
        @test 50. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_2", TS[2], "S1")
        #S2 : need both generators at TS2, prod_1_2 can be started gratis at TS1
        # => we use prod_1_2 since ts1, to get its free starting (starting it at TS2 would cost less prop_cost but <e would pay for starting)
        # prod_1_1 is use right from TS1 even if not really needed cause we will pay for starting anyways, so at least use it at TS1 to reduce prop_cost
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[1], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_1", TS[2], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S2")
        @test 15. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_1", TS[1], "S2")
        @test 10. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_2", TS[1], "S2")
        @test 100. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_1", TS[2], "S2")
        @test 65. ≈ PSCOPF.get_prod_value(context.market_schedule, "prod_1_2", TS[2], "S2")

        #reset original value
        PSCOPF.add_uncertainty!(uncertainties, ech, "bus_1", DateTime("2015-01-01T11:15:00"), "S2", 65.)
    end

    #=
    For now, we simply impose previous decided values (reference is the preceding market_schedule)
     (=> gratis starts are not used properly)
    =#
    @testset "energy_market_test_gratis_start_not_used_for_decided_values" begin
        #bus2, S2, TS:11h15 : high demand
        PSCOPF.add_uncertainty!(uncertainties, ech, "bus_1", DateTime("2015-01-01T11:15:00"), "S2", 165.)

        # firmness
        firmness_test = PSCOPF.Firmness(
            SortedDict("prod_1_1" => SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.FREE,
                                                Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.FREE),
                        "prod_1_2" => SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.DECIDED,
                                                Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.DECIDED) ),
            SortedDict( "prod_1_1" => SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.FREE,
                                                Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.FREE),
                        "prod_1_2" => SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.FREE,
                                                Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.FREE), )
            )

        # initial generators state
        generators_init_state = SortedDict(
            "prod_1_1" => PSCOPF.OFF,
            "prod_1_2" => PSCOPF.OFF
        )
        context = PSCOPF.PSCOPFContext(network, TS, PSCOPF.PSCOPF_MODE_1,
                                        generators_init_state,
                                        uncertainties, nothing)

        # For market, prod_1_2 is decided, it is OFF in ts1, ON in ts2 => automatically fixed in the next step
        context.market_schedule = PSCOPF.Schedule(PSCOPF.Market(), Dates.DateTime("2015-01-01T06:00:00"), SortedDict(
                                        "prod_1_1" => PSCOPF.GeneratorSchedule("prod_1_1",
                                            SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.UncertainValue{PSCOPF.GeneratorState}(missing,
                                                                                                                    SortedDict("S1"=>PSCOPF.ON, "S2"=>PSCOPF.ON)),
                                                        Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.UncertainValue{PSCOPF.GeneratorState}(missing,
                                                                                                                    SortedDict("S1"=>PSCOPF.ON, "S2"=>PSCOPF.ON))
                                                        ),
                                            SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.UncertainValue{PSCOPF.Float64}(missing,
                                                                                                                    SortedDict("S1"=>missing, "S2"=>missing)),
                                                        Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.UncertainValue{PSCOPF.Float64}(missing,
                                                                                                                    SortedDict("S1"=>missing, "S2"=>missing))
                                                        ),
                                            ),
                                        "prod_1_2" => PSCOPF.GeneratorSchedule("prod_1_2",
                                            SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.UncertainValue{PSCOPF.GeneratorState}(PSCOPF.OFF,
                                                                                                                    SortedDict("S1"=>PSCOPF.OFF, "S2"=>PSCOPF.OFF)),
                                                        Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.UncertainValue{PSCOPF.GeneratorState}(PSCOPF.ON,
                                                                                                                    SortedDict("S1"=>PSCOPF.ON, "S2"=>PSCOPF.ON))
                                                        ),
                                            SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.UncertainValue{PSCOPF.Float64}(missing,
                                                                                                                    SortedDict("S1"=>missing, "S2"=>missing)),
                                                        Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.UncertainValue{PSCOPF.Float64}(missing,
                                                                                                                    SortedDict("S1"=>missing, "S2"=>missing))
                                                        ),
                                            )
                                        )
                                )

        # TSO starts prod_1_2 for ts1 too
        context.tso_schedule = PSCOPF.Schedule(PSCOPF.TSO(), Dates.DateTime("2015-01-01T06:00:00"), SortedDict(
                                        "prod_1_1" => PSCOPF.GeneratorSchedule("prod_1_1",
                                            SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.UncertainValue{PSCOPF.GeneratorState}(missing,
                                                                                                                    SortedDict("S1"=>PSCOPF.ON, "S2"=>PSCOPF.ON)),
                                                        Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.UncertainValue{PSCOPF.GeneratorState}(missing,
                                                                                                                    SortedDict("S1"=>PSCOPF.ON, "S2"=>PSCOPF.ON))
                                                        ),
                                            SortedDict{Dates.DateTime, PSCOPF.UncertainValue{Float64}}(),
                                            ),
                                        "prod_1_2" => PSCOPF.GeneratorSchedule("prod_1_2",
                                            SortedDict(Dates.DateTime("2015-01-01T11:00:00") => PSCOPF.UncertainValue{PSCOPF.GeneratorState}(PSCOPF.ON,
                                                                                                                    SortedDict("S1"=>PSCOPF.ON, "S2"=>PSCOPF.ON)),
                                                        Dates.DateTime("2015-01-01T11:15:00") => PSCOPF.UncertainValue{PSCOPF.GeneratorState}(PSCOPF.ON,
                                                                                                                    SortedDict("S1"=>PSCOPF.ON, "S2"=>PSCOPF.ON))
                                                        ),
                                            SortedDict{Dates.DateTime, PSCOPF.UncertainValue{Float64}}(),
                                            )
                                        )
                                )

        market = PSCOPF.EnergyMarket()
        result = PSCOPF.run(market, ech, firmness_test,
                    PSCOPF.get_target_timepoints(context),
                    context)
        PSCOPF.update_market_schedule!(context, ech, result, firmness_test, market)

        # Solution is optimal
        @test PSCOPF.get_status(result) == PSCOPF.pscopf_OPTIMAL

        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S1")
        @test PSCOPF.OFF == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[1], "S2")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S1")
        @test PSCOPF.ON == PSCOPF.get_commitment_value(context.market_schedule, "prod_1_2", TS[2], "S2")
        @test value(result.objective_model.start_cost)  ≈ 2*45000
            # prod1 started in 2 scenarios at TS1
            # prod2 started in both scenarios at TS2, this decision was already decided/definitive/firm in the input market schedule
            # => the cost was already paid by the market in the preceding ech

        #reset original value
        PSCOPF.add_uncertainty!(uncertainties, ech, "bus_1", DateTime("2015-01-01T11:15:00"), "S2", 65.)
    end

end