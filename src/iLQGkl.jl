"""
    `x, u, traj_new, Vx, Vxx, cost, trace = iLQGkl(dynamics,costfun,derivs, x0, traj_prev, model;
        constrain_per_step = false,
        kl_step            = 0,
        lims               = [],                    # Control signal limits ::Matrix ∈ R(m,2)
        tol_fun            = 1e-7,
        tol_grad           = 1e-4,
        max_iter           = 50,
        print_head         = 10,                    # Print headers this often
        print_period       = 1,                     # Print this often
        reduce_ratio_min   = 0,                     # Not used ATM
        diff_fun           = -,
        verbosity          = 2,                     # ∈ (0,3)
        plot_fun           = x->0,                  # Not used
        cost               = [],                    # Supply if pre-rolled trajectory supplied
        ηbracket           = [1e-8,1,1e16],         # dual variable bracket [min_η, η, max_η]
        del0               = 0.0001,                # Start of dual variable increase
        gd_alpha           = 0.01                   # Step size in GD (ADAMOptimizer) when constrain_per_step is true
        )`

Solves the iLQG problem with constraints on control signals `lims` and bound on the KL-divergence `kl_step` from the old trajectory distribution `traj_prev::GaussianPolicy`.

To solve the maximum entropy problem, use controller `controller(xi,i)  = u[:,i] + K[:,:,i]*(xi-x[:,i]) + chol(Σ)*randn(m)` where `K` comes from `traj_new`. Note that multiplying the cost by a constant changes the relative weight between the cost term and the entropy term, i.e., higher cost produces less noise through chol(Σ) since (Σ = Qᵤᵤ⁻¹).
"""
function iLQGkl(dynamics,costfun,derivs, x0, traj_prev, model;
    constrain_per_step = false,
    kl_step            = 0,
    lims               = [],
    tol_fun            = 1e-7,
    tol_grad           = 1e-4,
    max_iter           = 50,
    print_head         = 10,
    print_period       = 1,
    reduce_ratio_min   = 0,
    diff_fun           = -,
    verbosity          = 2,
    plot_fun           = x->0,
    cost               = [],
    ηbracket           = [1e-8,1,1e16], # min_η, η, max_η
    del0               = 0.0001,
    gd_alpha           = 0.01
    )
    debug("Entering iLQG")

    # --- initial sizes and controls
    u            = copy(traj_prev.k) # initial control sequence
    n            = size(x0, 1) # dimension of state vector
    m,N          = size(u) # dimension of control vector and number of state transitions
    traj_new     = GaussianPolicy(Float64)
    k_old = copy(traj_prev.k)
    traj_prev.k *= 0 # We are adding new k to u, so must set this to zero for correct kl calculations
    ηbracket     = copy(ηbracket) # Because we do changes in this Array
    if constrain_per_step
        ηbracket = ηbracket.*ones(1,N)
        kl_step = kl_step*ones(N)
    end
    η = view(ηbracket,2,:)

    # --- initialize trace data structure
    trace = [Trace() for i in 1:min( max_iter+1,1e6)]
    trace[1].iter = 1

    # --- initial trajectory
    debug("Checking initial trajectory")
    if size(x0,2) == N
        debug("# pre-rolled initial forward pass, initial traj provided")
        x        = x0
        diverge  = false
        isempty(cost) && error("Initial trajectory supplied, initial cost must also be supplied")
    else
        error("pre-rolled initial trajectory must be of correct length (size(x0,2) == N)")
    end

    trace[1].cost = sum(cost)

    # constants, timers, counters
    Δcost              = 0.
    expected_reduction = 0.
    divergence         = 0.
    step_mult          = 1.
    iter               = 0
    last_head          = print_head
    g_norm             = Vector{Float64}()
    Vx = Vxx           = emptyMat3(Float64)
    xnew,unew,costnew  = similar(x),similar(u),Vector{Float64}(N)
    t_start            = time()
    verbosity > 0 && @printf("\n---------- begin iLQG ----------\n")
    satisfied          = false # Indicating KL-constraint satisfied

    # ====== STEP 1: differentiate dynamics and cost along new trajectory
    trace[1].time_derivs = @elapsed fx,fu,fxx,fxu,fuu,cx,cu,cxx,cxu,cuu = derivs(x, u)


    local xnew,unew,costnew,sigmanew

    dV               = Vector{Float64}() # Needed to calculate expected reduction
    reduce_ratio     = 0.
    kl_cost_terms    = (∇kl(traj_prev), ηbracket) # This tuple is sent into back_pass, elements in ηbracket are mutated.
    for iter = 1:(constrain_per_step ? 0 : max_iter) # Single KL constraint
        trace[iter].iter = iter
        diverge = 1
        # ====== STEP 2: backward pass, compute optimal control law and cost-to-go
        back_pass_done = false
        while diverge > 0 # Done when regularization (through 1/η) for Quu is high enough
            tic()
            # debug("Entering back_pass with η=$ηbracket")
            # η is the only regularization when optimizing KL, hence λ = 0 and regType arbitrary
            diverge, traj_new,Vx, Vxx,dV =  back_pass_gps(cx,cu,cxx,cxu,cuu,fx,fu, lims,x,u,kl_cost_terms) # Set λ=0 since we use η

            trace[iter].time_backward = toq()

            if diverge > 0
                ηbracket[2] .+= del0 # η increased, used in back_pass through kl_cost_terms
                # Higher η downweights the original Q function and upweights KL-cost terms
                del0 *= 2
                if verbosity > 2; println("Inversion failed at timestep $diverge. η-bracket: ", ηbracket); end
                if ηbracket[2] >  0.999ηbracket[3] #  terminate ?
                    verbosity > 0 && @printf("\nEXIT: η > ηmax (back_pass failed)\n")
                    break
                end

            end
        end

        #  check for termination due to small gradient
        g_norm = mean(maximum(abs.(traj_new.k) ./ (abs.(u)+1),1))
        trace[iter].grad_norm = g_norm

        # ====== STEP 3: Forward pass

        tic()
        # debug("#  entering forward_pass")
        xnew,unew,costnew = forward_pass(traj_new, x0[:,1] ,u, x,1,dynamics,costfun, lims, diff_fun)
        sigmanew = forward_covariance(model, x, u, traj_new)
        traj_new.k .+= traj_prev.k # unew = k_new + k_old + Knew*Δx, this doesn't matter since traj_prev.k set to 0 above
        Δcost    = sum(cost) - sum(costnew)
        expected_reduction = -(dV[1] + dV[2]) # According to second order approximation

        reduce_ratio = if expected_reduction > 1e-10
            Δcost/expected_reduction
        else
            warn("negative expected reduction: should not occur")
            sign(Δcost)
        end
        # calc_η modifies the dual variables η according to current constraint_violation
        ηbracket, satisfied, divergence = calc_η(xnew,x,sigmanew,ηbracket, traj_new, traj_prev, kl_step)
        trace[iter].time_forward = toq()
        debug("Forward pass done: η: $ηbracket")

        # ====== STEP 4: accept step (or not), print status

        #  print headings
        if verbosity > 1 && iter % print_period == 0
            if last_head == print_head
                last_head = 0
                @printf("%-12s", "iteration     est. cost    reduction     expected    gradient    log10(η)    divergence      entropy\n")
            end
            @printf("%-14d%-14.6g%-14.3g%-14.3g%-12.3g%-12.2f%-14.3g%-12.3g\n",
            iter, sum(costnew), Δcost, expected_reduction, g_norm, log10(mean(η)), mean(divergence), entropy(traj_new))
            last_head += 1
        end
        #  update trace
        trace[iter].alpha        = 1
        trace[iter].improvement  = Δcost
        trace[iter].cost         = sum(costnew)
        trace[iter].reduce_ratio = reduce_ratio
        trace[iter].divergence   = mean(divergence)
        trace[iter].η            = ηbracket[2]

        # Termination checks
        # if g_norm <  tol_grad && divergence-kl_step > 0 # In this case we're only going to get even smaller gradients and might as well quit
        #     verbosity > 0 && @printf("\nEXIT: gradient norm < tol_grad while constraint violation too large\n")
        #     break
        # end
        if satisfied # KL-constraint is satisfied and we're happy (at least if Δcost is positive)
            plot_fun(x)
            verbosity > 0 && @printf("\nSUCCESS: abs(KL-divergence) < kl_step\n")
            break
        end
        if ηbracket[2] >  0.999ηbracket[3]
            verbosity > 0 && @printf("\nEXIT: η > ηmax\n")
            break
        end
        graphics(xnew,unew,cost,traj_new.K,Vx,Vxx,fx,fxx,fu,fuu,trace[1:iter],0)
    end # !constrain_per_step

    if constrain_per_step # This implements the gradient descent procedure for η
        optimizer = ADAMOptimizer(kl_step, α=gd_alpha)
        for iter = 1:max_iter
            diverge = 1
            del = del0*ones(N)
            while diverge > 0
                diverge, traj_new,Vx, Vxx,dV = back_pass_gps(cx,cu,cxx,cxu,cuu,fx,fu, lims,x,u,kl_cost_terms)
                if diverge > 0
                    delind = diverge # This is very inefficient since back_pass only returs a single diverge per call.
                    ηbracket[2,delind] .+= del[delind]
                    del[delind] *= 2
                    if verbosity > 2; println("Inversion failed at timestep $diverge. η-bracket: ", mean(η)); end
                    if all(ηbracket[2,:] .>  0.999ηbracket[3,:])
                        # TODO: This termination criteria could be improved
                        verbosity > 0 && @printf("\nEXIT: η > ηmax\n")
                        break
                    end
                end
            end

            xnew,unew,costnew = forward_pass(traj_new, x0[:,1] ,u, x,1,dynamics,costfun, lims, diff_fun)
            sigmanew = forward_covariance(model, x, u, traj_new)
            traj_new.k .+= traj_prev.k # unew = k_new + k_old + Knew*Δx
            Δcost                 = sum(cost) - sum(costnew)
            expected_reduction    = -(dV[1] + dV[2])
            reduce_ratio          = Δcost/expected_reduction
            divergence            = kl_div_wiki(xnew,x,sigmanew, traj_new, traj_prev)
            constraint_violation  = divergence - kl_step
            lη                    = log.(η) # Run GD in log-space (much faster)
            η                    .= exp.(optimizer(lη, -constraint_violation, iter))
            # η                    .= optimizer(η, -constraint_violation, iter)
            # println(maximum(constraint_violation), " ", extrema(η), " ", indmax(constraint_violation))
            # println(round.(constraint_violation,4))
            η                    .= clamp.(η, ηbracket[1,:], ηbracket[3,:])
            g_norm                = mean(maximum(abs.(traj_new.k) ./ (abs.(u)+1),1))
            trace[iter].grad_norm = g_norm
            # @show maximum(constraint_violation)
            if all(divergence .< 2*kl_step) && mean(constraint_violation) < 0.1*kl_step[1]
                satisfied = true
                break
            end
            if verbosity > 1 && iter % print_period == 0
                if last_head == print_head
                    last_head = 0
                    @printf("%-12s", "iteration     est. cost    reduction     expected    log10(η)    divergence      entropy\n")
                end
                @printf("%-14d%-14.6g%-14.3g%-14.3g%-12.3f%-12.3g%-14.3g\n",
                iter, sum(costnew), Δcost, expected_reduction, mean(log10.(η)), mean(divergence), entropy(traj_new))
                last_head += 1
            end
        end
    end

    iter ==  max_iter &&  verbosity > 0 && @printf("\nEXIT: Maximum iterations reached.\n")
    # if costnew < 1.1cost # In this case we made an (approximate) improvement under the model and accept the changes
        x,u,cost  = xnew,unew,costnew
        traj_new.k = copy(u)

    # else
    #     traj_new = traj_prev
    #     verbosity > 0 && println("Cost (under model) increased, did not accept changes to u")
    # end
    traj_prev.k = k_old
    any((divergence .> kl_step) .& (abs.(divergence - kl_step) .> 0.1*kl_step)) && warn("KL divergence too high for some time steps when done")
    verbosity > 0 && print_timing(trace,iter,t_start,cost,g_norm,mean(ηbracket[2,:]))

    return x, u, traj_new, Vx, Vxx, cost, trace
end
