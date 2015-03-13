"""genetic algorithm solver for the constrained vehicle routing problem (CVRP)"""

import numpy as np
cimport numpy as np


import clark_wright
import cvrp
from routes cimport Route, steepest_improvement


cpdef np.ndarray genes_to_routes(np.ndarray genes):
    """GENES -> ROUTES
       0 is used as depot"""
    assert(genes[0] == 0)
    assert(genes[-1] == 0)
    cdef current_route = [0]
    cdef all_routes = []
    for client in genes[1:]:
        if client == 0:
            # end of the route
            current_route.append(0)
            all_routes.append(Route(np.array(current_route)))
            current_route = [0]
        else:
            current_route.append(client)
    return np.array(all_routes)


cpdef np.ndarray routes_to_genes(routes):
    """ROUTES -> GENES"""
    concatenated = np.array([0])
    for route in routes:
        concatenated = np.concatenate((concatenated, route[1:]))
    return concatenated


cpdef set find_unserved_clients(list routes, int num_clients):
    assert(num_clients > 0)
    cdef set clients = set(np.arange(1, num_clients+1))
    cdef set served_clients = set()
    for route in routes:
        served_clients = served_clients.union(set(route.nodes))
    return all.difference(served_clients)


cpdef Solution BRBAX(cvrp_problem,
                     Solution parent1, Solution parent2,
                     np.ndarray route_info,
                     int num_clients):
    """"Optimised crossover genetic algoritm for capacited vehicle routing problem"
     by Nazif and Lee, 2012, modified with the power of savings tm"""

    # select m / 2 best routes from parent 1, by best we mean the ones having
    # that have the least discrepancy with the capacity limit
    cdef int to_select = np.round(len(parent1.routes)/2.)

    cdef np.ndarray capacity_difference = np.abs(np.subtract(route_info["cap"],
                                                             cvrp_problem.vehicle_capacity))
    cdef list inherited_routes = parent1.routes[np.argpartition(abs_capacity_difference, to_select)[: to_select]]

    # let's reassemble the rest of the routes with savings :)
    cdef list unserved_clients = sorted(find_unserved_clients(inherited_routes, cvrp_problem.num_clients))
    cdef list new_routes = [Route([0, i, 0], cvrp_problem.weights[i]) for i in range(1, cvrp_problem.num_clients+1)]
    cdef list remaining_routes = clark_wright.cw_parallel(new_routes,
                                                          cvrp_problem.distance_matrix,
                                                          cvrp_problem.vehicle_capacity)

    # concatenate the routes
    return Solution(inherited_routes.extend(remaining_routes))



#cpdef mutate(Solution ind):
    #"""insertion mutation operator (Graglia et al.)"""
    #cdef int swap1 = np.random.randint(1, len(ind.genes)-1)
    #cdef int swap2 = np.random.randint(1, len(ind.genes)-1)
    #tmp = ind.genes[swap2]
    #ind.genes[swap2] = ind.genes[swap1]
    #ind.genes[swap1] = tmp
    ## update routes
    #ind.routes = genes_to_routes(ind.genes)
    #return


cdef tuple select_2(int low, int high):
    """select 2 different random integers in the interval"""
    # high will be the LENGTH of the list
    assert(high - 1 > low), "interval is nonsensical"
    cdef int l = np.random.randint(low, high)
    cdef int h = np.random.randint(low, high)
    while (l == h):
        h = np.random.randint(low, high)
    return (l, h)


cpdef list binary_tournament_selection(Population population, int num_to_select):
    """binary tournament selection"""
    assert(num_to_select > 0)
    cdef list selected = []
    cdef int index1 = 0
    cdef int index2 = 0
    cdef int pop_size = len(population.individuals)
    for index in range(num_to_select):
        index1, index2 = select_2(0, pop_size)
        if population[index1].score < population[index2].score:
            selected.append(copy.copy(population[index1]))
        else:
            selected.append(copy.copy(population[index2]))
    return selected


cpdef list initialize_population(cvrp_problem, int pop_size, int k):
    """use Clark & Wright with random choice (up to k worst) to initialize"""
    assert(pop_size > 0)
    assert(k > 0)

    # let's extract a few variables from the problem settings
    cdef np.ndarray distance_matrix = cvrp_problem.distance_matrix
    cdef np.ndarray weights = cvrp_problem.weights

    cdef list routes = [Route([0, i, 0], prob.weights[i]) for i in range(1, cvrp_problem.num_clients+1)]
    cdef list individuals_list = []

    # add the "best" clark wright solution (the one that selects only the best saving)
    # the calculation should quite fast (about a quarter as small, maybe more)
    individuals_list.append(clark_wright.cw_parallel(routes, cvrp_problem.distance_matrix, cvrp_problem.vehicle_capacity))

    # add now, until the population is filled
    for iteration in range(pop_size - 1):
        individuals_list.append(cw_parallel_random(routes, distance_matrix, vehicle_capacity, k))

    return individuals_list


cpdef double calculate_score(Solution ind,
                             double vehicle_capacity,
                             np.ndarray distance_matrix,
                             np.ndarray weights,
                             double penalty=1000.):
    """calculate the fitness based on Graglia et al."""
    route_info = get_individual_information(ind, distance_matrix, weights)
    cdef double overcap = 0.
    cdef double total_distance = 0.
    cdef double score
    for (distance, capacity_used) in route_info:
        #print "distance: {0} capacity: {1}".format(distance, capacity_used)
        if capacity_used > vehicle_capacity:
            overcap += capacity_used - vehicle_capacity
        total_distance += distance
    score = (overcap * penalty) + total_distance
    return score


cpdef solve(problem,
            int population_size,
            int num_generations,
            int opt_step=75,
            double recombination_prob=0.65,
            double mutation_prob=0.1):
    """solve the cvrp problem using a simple genetic algorithm"""
    cdef Population population = initialize_population(population_size,
                                                       problem.num_clients,
                                                       num_vehicles)
    cdef list best_individuals = []
    cdef Solution parent1, parent2, child

    # start the loop
    for generation_index in range(num_generations):
        if generation_index%25 == 0:
            print generation_index

        current_best_index = 0
        current_best_score = np.inf
        for index, individual in enumerate(population.individuals):
            # optimize the routes and assign the new scores
            if generation_index%opt_step==0:
                optimize_routes(individual, problem.distance_matrix)
            individual.score = calculate_score(individual,
                                               problem.vehicle_capacity,
                                               problem.distance_matrix,
                                               problem.weights)
            if individual.score < current_best_score:
                current_best_score = individual.score
                current_best_index = index
        best_individuals.append(copy.copy(population.individuals[current_best_index]))
        # selection process
        parents = binary_tournament_selection(population, population_size*2)
        children = []
        for i in range(population_size):
            parent1 = parents[i*2]
            parent2 = parents[(i*2)+1]

            # crossover, probability = 0.65
            if np.random.rand() < recombination_prob:
                p1_info = get_individual_information(parent1, problem.distance_matrix, problem.weights)
                child = BRBAX(parent1, parent2, p1_info, problem.vehicle_capacity)

            else:
                child = copy.copy(parent1)

            if np.random.rand() < mutation_prob:
                mutate(child)
            children.append(child)

        population = Population(np.array(children))

    tmp_scores = []
    for individual in population.individuals:
        # optimize the routes and assign the new scores
        optimize_routes(individual, problem.distance_matrix)
        individual.score = calculate_score(individual,
                                           problem.vehicle_capacity,
                                           problem.distance_matrix,
                                           problem.weights)
        tmp_scores.append(individual.score)
    # add the last generation's best to the best_individuals
    best_individuals.append(population.individuals[np.argmin(tmp_scores)])
    return population, best_individuals