"""tabu solver for the CVRP, inspired by Taillard 1993"""

import numpy as np
cimport numpy as np

import clark_wright as cw

cimport cvrp
from cvrp cimport CVRPProblem

cimport routes
from routes cimport Route

cimport interchange
from interchange cimport Move, find_best_move

from two_opt import steepest_improvement

cimport solution
from solution cimport Solution

import progress_bar


cdef class TabuList:
    cdef np.ndarray matrix

    def __init__(self, int num_clients, int num_routes):
        """client 0 will be the null customer"""
        self.matrix = np.empty((num_clients + 1, num_routes), dtype=int)
        self.matrix.fill(np.iinfo(int).min)

    cpdef is_tabu(self, int client1, int client2, int current_iteration):
        """verify if the move is tabu"""
        if self.matrix[client1, client2] > current_iteration:
            return False
        else:
            return True

    cpdef set_tabu(self, Move mv, int until_iteration):
        """set the move tabu until specified iteration"""
        self.matrix[mv.client1, mv.client2] = until_iteration
        self.matrix[mv.client2, mv.client1] = until_iteration


cpdef Move transfer_to_tabu(Route route1, Route route2,
                            np.ndarray distance_matrix,
                            np.ndarray weights,
                            double vehicle_capacity,
                            int iteration,
                            TabuList tabulist):
    """c1 in route1 transfers to route2"""
    cdef int client
    cdef int insertion_point
    cdef double distance_difference
    cdef int best_client = 0
    cdef int best_insertion_point = 0
    cdef double best_distance_difference = np.inf

    for index in range(1, len(route1.nodes)-1):
        # assign the client
        client = route1.nodes[index]
        if not tabulist.is_tabu(client, 0 , current_iteration):
            # the distance decrease when the current client is taken out of the route1
            removal_difference = removal_cost(route1, index, distance_matrix)
            # the distance increase when the current client is inserted in route2
            insertion_difference, insertion_point = least_insertion_cost(client,
                                                                        route2,
                                                                        distance_matrix,
                                                                        weights,
                                                                        vehicle_capacity)
            # assign
            distance_difference = removal_difference + insertion_difference
            # assign if new optimal found
            if distance_difference < best_distance_difference:
                best_client = client
                best_insertion_point = insertion_point
                best_distance_difference = distance_difference
    return Move(best_distance_difference, best_client, best_insertion_point, 0, 0)


cpdef Move transfer_from_tabu(Route route1, Route route2,
                                 np.ndarray distance_matrix,
                                 np.ndarray weights,
                                 double vehicle_capacity,
                                 int iteration,
                                 TabuList tabulist):
    """inverse of transfer to"""
    cdef Move move = transfer_to(route2, route1,
                                 distance_matrix,
                                 weights,
                                 vehicle_capacity,
                                 iteration,
                                 tabulist)
    # invert the insertion point indices
    move.r1_index, move.r2_index = move.r2_index, move.r1_index
    # invert the client indices
    move.client1, move.client2 = move.client2, move.client1
    return move


cpdef Move best_client_interchange_tabu(Route route1,
                                        Route route2,
                                        np.ndarray distance_matrix,
                                        np.ndarray weights,
                                        double vehicle_capacity,
                                        int iteration,
                                        TabuList tabulist):
    """lambda interchange (1, 1), more costly than the simple shifts"""
    cdef int ind1, ind2, client1, client2
    cdef double removal_savings1, removal_savings2
    cdef double insertion_cost1, insertion_cost2

    # keep the best move seen yet
    cdef Move best_move = Move(np.inf, 0, 0, 0, 0)

    for ind1 in range(1, len(route1.nodes)-1):
        # remove the client in route 1
        removal_savings1 = removal_cost(route1, ind1, distance_matrix)
        client1 = route1.remove_client_index(ind1, weights)

        for ind2 in range(1, len(route2.nodes)-1):
            # remove the client in route 2
            removal_savings2 = removal_cost(route2, ind2, distance_matrix)
            client2 = route2.remove_client_index(ind2, weights)

            if not tabulist.is_tabu(client1, client2, iteration):
                # calculate the savings now
                insertion_cost1, insertion_point2 = least_insertion_cost(client1, route2, distance_matrix, weights, vehicle_capacity)
                insertion_cost2, insertion_point1 = least_insertion_cost(client2, route1, distance_matrix, weights, vehicle_capacity)
                overall_dist_diff = insertion_cost1 + insertion_cost2 + removal_savings1 + removal_savings2

                # update best solution
                if overall_dist_diff < best_move.value:
                    best_move = Move(overall_dist_diff, client1, insertion_point2, client2, insertion_point1)

            # add back the client in the second route at previous spot
            route2.add_client(ind2, client2, weights)

        # add back the client in the first route at previous spot
        route1.add_client(ind1, client1, weights)
    return best_move


cpdef Move find_best_move_tabu(Route route1, Route route2,
                               np.ndarray distance_matrix,
                               np.ndarray weights,
                               double vehicle_capacity,
                               int iteration,
                               TabuList tabulist):
    """return the best move between the two routes"""
    cdef Move removal, insertion, interchange, best
    # route 1 -> route 2
    removal = transfer_to_tabu(route1, route2,
                               distance_matrix,
                               weights,
                               vehicle_capacity,
                               iteration,
                               tabulist)
    best = removal
    # route 2 -> route 1
    insertion  = transfer_from_tabu(route1, route2,
                                    distance_matrix,
                                    weights,
                                    vehicle_capacity,
                                    iteration,
                                    tabulist)
    if insertion.value < best.value:
        best = insertion
    # route 1 <-> route 2
    swap = best_client_interchange_tabu(route1, route2,
                                        distance_matrix,
                                        weights,
                                        vehicle_capacity,
                                        iteration,
                                        tabulist)
    if swap.value < best.value:
        best = swap
    return best

cdef class MovesMatrixTabu(MovesMatrix):
    """modified moves matrix taking tabu into account"""

    cpdef update(self, Solution sol,
                 int index1, int index2,
                 np.ndarray distance_matrix,
                 np.ndarray weights,
                 double vehicle_capacity):
        """update all moves implying route 1 and route 2"""
        cdef Move move
        cdef Route route1, route2
        cdef int num_routes = len(sol.routes)
        cdef int i1, i2
        for i1 in range(0, num_routes-1):
            route1 = sol.routes[i1]
            for i2 in range((i1+1), num_routes):
                if i1==index1 or i1==index2 or i2==index1 or i2==index2:
                    route2 = sol.routes[i2]
                    move = find_best_move_tabu(route1, route2,
                                               distance_matrix,
                                               weights,
                                               vehicle_capacity,
                                               iteration,
                                               tabulist)
                    self.matrix[i1, i2] = move
                    self.matrix[i2, i1] = move

    cpdef update_tabu(MovesMatrixTabu self,
                      Solution sol,
                      int client,
                      np.ndarray distance_matrix,
                      np.ndarray weights,
                      double vehicle_capacity,
                      int iteration,
                      TabuList tabulist):
        """update all the moves implying the client"""
        assert(client != 0), "invalid client"
        cdef int route_index = -1
        cdef int index
        cdef Route route

        # find the route in which the client belongs
        for index, route in enumerate(sol.routes):
            if client in route.nodes:
                route_index = index
                break
        # update all routes implicating the 
        cdef int num_routes = len(sol.routes)
        cdef int i1, i2
        for i1 in range(0, num_routes-1):
            route1 = sol.routes[i1]
            for i2 in range((i1+1), num_routes):
                # if the specified route is amongst them
                if i1==route_index or i2==route_index:
                    route2 = sol.routes[i2]
                    move = find_best_move_tabu(route1, route2,
                                               distance_matrix,
                                               weights,
                                               vehicle_capacity,
                                               iteration,
                                               tabulist)
                    self.matrix[i1, i2] = move
                    self.matrix[i2, i1] = move
        return


# GENERATE INITIAL SOLUTION

cpdef Solution generate_initial_solution(CVRPProblem prob):
    """generate initial solution with Clark & Wright savings"""
    cdef list routes = [Route([0, i, 0], prob.weights[i])
                                         for i in range(1, prob.num_clients+1)]
    cdef Solution sol = Solution(cw.cw_parallel(routes,
                                                prob.distance_matrix,
                                                prob.vehicle_capacity))
    # apply 2-opt steepest improvement
    cdef Route route
    for route in sol.routes:
        steepest_improvement(route, prob.distance_matrix)

    # sort the routes by their angle to the depot
    solution.sort_routes_by_angle(sol, prob.positions)
    return sol


cpdef Solution generate_new_solution(CVRPProblem prob, int k):
    """generate new solution with Clark & Wright random savings"""
    cdef list routes = [Route([0, i, 0], prob.weights[i])
                                         for i in range(1, prob.num_clients+1)]
    cdef Solution sol = Solution(cw.cw_parallel_random(routes,
                                                       prob.distance_matrix,
                                                       prob.vehicle_capacity,
                                                       k))

    # apply 2-opt steepest improvement
    cdef Route route
    for route in sol.routes:
        steepest_improvement(route, prob.distance_matrix)

    # sort the routes by their angle to the depot
    solution.sort_routes_by_angle(sol, prob.positions)
    return sol


cpdef solve(CVRPProblem prob, int num_iterations):
    """solve the cvrp problem using tabu search"""

    # initialize a solution using Clark & Wright savings
    cdef Solution sol = generate_initial_solution(prob)
    cdef Solution best_solution = sol

    sol.score = sol.get_distance(prob.distance_matrix)
    cdef double score = sol.score
    cdef double best_score = score

    # create the Tabu objects and parameters (tabu list and others)
    cdef TabuList tabu_list = TabuList(prob.num_clients, len(sol.routes))
    cdef MovesMatrix possible_moves = MovesMatrix(sol,
                                                  prob.distance_matrix,
                                                  prob.weights,
                                                  prob.vehicle_capacity)
    cdef np.ndarray tabu_to_remove = np.zeros(num_iterations, dtype=[("x", int), ("y", int)])

    # between 0.4 and 0.6 * n of clients
    cdef int tabu_duration = np.random.uniform(0.4, 0.6) * prob.num_clients
    cdef int tabu_expiration

    # misc objects
    p = progress_bar.ProgressBar("Tabu Search")
    cdef Move move
    cdef int x, y
    cdef int tabu_remov1, tabu_remov2

    for current_iteration in range(num_iterations):
        # TABU REMOVAL
        tabu_remov1, tabu_remov2 = tabu_to_remove[current_iteration]
        if tabu_remov1 != 0 or tabu_remov2!= 0:
            # update the routes involving moves that aren't tabu anymore
            possible_moves.update_tabu(sol,
                                       tabu_remov1,
                                       tabu_remov2,
                                       prob.distance_matrix,
                                       prob.weights,
                                       prob.vehicle_capacity)

        p.update(float(current_iteration) / max_iterations)

        # choose feasable and admissible move in neighborhood
        move = 

        # if there are no admissible solutions in the neighborhood
        #  a new solution is chosen from random savings
        if(delta == np.inf):
            current_solution, current_score, tabu_list, moves_matrix = restart(current_solution, current_score, tabu_list, moves_matrix)
        # if the proposed move is admissible
        else:
            # assign the tabu status
            tabu_expiration = current_iteration + tabu_duration
            tabu_list.set_tabu(selected_move[0], selected_move[1], tabu_expiration)

            # update the current solution
            current_solution = update_solution(current_solution, selected_move)

    # clean the progress bar
    p.clean()
    return best_solution, best_score
