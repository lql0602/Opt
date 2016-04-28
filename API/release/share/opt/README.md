TODO: instructions to build the API, general overview of how it works, where is the example.

Beta-software warning.

Using the Opt C/C++ API
=======================

    OptState * Opt_NewState();
    
Allocate a new independant context for Opt
    
---
    
    Problem * Opt_ProblemDefine(OptState * state,const char * filename,const char * solverkind);

Load the energy specification from 'filename' and initialize a solver of type 'solverkind' (currently only one solver is supported: 'gaussNewtonGPU').
See writing energy specifications for how to describe energy functions.

---

    void Opt_ProblemDelete(OptState * state, Problem * problem);

Delete memory associated with the Problem object.

---

    Plan * Opt_ProblemPlan(OptState * state,Problem * problem, unsigned int * dimensions);

Allocate intermediate arrays necessary to run 'problem' on the dimensions listed in 'dimensions'
How the dimensions are used is based on the problem specification (see 'binding values' in 'writing energy specifications')

---

    void Opt_PlanFree(OptState * state, Plan * plan);

Delete the memory associated with the plan.

---

    void Opt_ProblemSolve(OptState * state,Plan * plan,void ** problemparams,void ** solverparams);

Run the solver until completion using the plan 'plan'. 'problemparams' are the problem-specific inputs 
and outputs that define the problem, including arrays, graphs, and problem paramaters
(see 'writing problem specifications'). 'solverparams' are the solver-specific parameter (e.g., 
number of iterations, see 'solver parameters')

---

    void Opt_ProblemInit(OptState * state,Plan * plan,void ** problemparams,void ** solverparams);
    int Opt_ProblemStep(OptState * state,Plan * plan,void ** problemparams,void ** solverparams);

Use these two functions to control the outer solver loop on your own. The arguments are the same as `Opt_ProblemSolve` but
the `Step` function returns between iterations of the solver. Problem parameters can be inspected and updated between calls to Step.
A zero return value indicates that the solver is finished according to its parameters.

    Opt_ProblemInit(...);
    while(Opt_ProblemStep(...) != 0) {
        // inspect and update problem state as desired.
    }
    // solver finished


Writing Energy Specifications
==============================

Specifications of the energy are written using an API embedded in Lua. 
Similar to SymPy or Mathematica, objects with overloaded operators in Lua are used to build up a symbolic expression of the energy. There are Lua functions to declare objects: dimensions, arrays (including unknown to be solved for),  and graphs.

These objects can be used to create residuals functions defined per-pixel in an array or per-edge in graph. The mathematical expressions of energy are built using overloaded operators defined on these objects. The 'Energy' function adds an expression to the overall energy of the system. 

A simple laplacian smoothing energy in this system would have the form:


    W = Dim("W",0) 
    H = Dim("H",1)
    X = Array2D("X",float,{W,H},0) 
    A = Array2D("A",float,{W,H},1)
    
    w_fit,w_reg = .1,.9
    
    -- overloaded operators allow you to defined mathematical expressions as energies
    fit = w_fit*(X(0,0) - A(0,0))
    
    -- register fitting energy
    Energy(fit) --fitting
    
    -- Energy function can be called multiple times or with multiple arguments
    -- to add more residual terms to the energy
    Energy(w_reg*(X(0,0) - X(1,0)),
           w_reg*(X(0,0) - X(0,1)))


The functions are described in more details below.

## Declaring the inputs/outputs of an energies ##
 
    dimension = Dim(name,dimensions_position)
    
Create a new dimension used to describe the size of Arrays. `dimensions_position` is the 0-based offset into the `dimensions` argument to `Opt_ProblemPlan` that will be bound to this value. See 'Binding Values'.

    local W =
    H = Dim("W",0), Dim("H",1)
    
---

    array = Array(name,type,dimlist,problemparams_position)
    array = Unknown(name,type,dimlist,problemparams_position)
    
Declare a new input to the problem (`Array`), or an unknown value to be solved for `Unknown`. Both return an Array object that can be used to formulate energies.

`name` is the name of the object, used for debugging 
`type` can be float, float2, float3, ...
`dimlist` is a Lua array of dimensions (e.g. `{W,H}`). Arrays can be 1, 2, or 3 dimensional but 3 dims has not been tested heavily.
`problemparams_position` is the 0-based offset into the `problemparams` argument to `Opt_ProblemSolve` that will be bound to this value. 

Examples:

    local Angle = Unknown("Angle",float, {W,H},1)
    local UrShape = Array("UrShape", float2,{W,H},2)	
    
---

    graph = Graph(name, problemparams_position_of_graph_size,
                 {vertexname, dimlist, problemparams_position_of_indices}*)

Declare a new graph that connects arrays together through hyper-edges.

`name` is a string for debugging.
`problemparams_position_of_graph_size` is the 0-based offset into the `problemparams` argument to `Opt_ProblemSolve` that will determine the number of edges in the graph.

The remaining arguments are used to define vertices in the hyper-edge of the graph.
Each vertex requires the following arguments:

     vertexname, dimlist, problemparams_position_of_indices
     
`vertexname` is the name of the vertex used in the energy specification.
`dimlist` is a Lua array of dimensions (e.g. `{W,H}`). Arrays can be 1, 2, or 3 dimensional but 3 dims has not been tested heavily. This vertex will be a pointer into any array of this dimension.
`problemparams_position_of_indices` is the 0-based offset into the `problemparams` argument to `Opt_ProblemSolve` that is an array of indexes the size of the number of edges in the graph, where each entry is an index into the dimension specified in `dimlist`. For 2- or 3- dimensional arrays the indices for both dimensions are listed sequentially `(int,int)`.
    
Example:

    N = Dim("N",0)
    local Angle = Unknown("Angle", float3,{N},0)		
    local G =  Graph("G", 1, "head", {N}, 2,
                             "tail", {N}, 3)
                             
    Energy(Angle(G.v0) - Angle(G.v1))

---

## Writing Energies ##

Energies are described using a mathematical expressions constructed using Lua object overloaded.

Values can be read from the arrays created with the `Array` or `Unknown` constructors. 

### Accessing values with Stencils or Graphs ###

    value = Angle(0,0) -- value of the 'Angle' array at the centered pixel
    value = Angle(1,0) -- value of the 'Angle' array at the pixel to the right of the centered pixel
    value = Angle(0,2) -- value of the 'Angle' array at the pixel two pixels above the centered pixel
    ...

Each expression is implicitly defined over an entire array or entire set of edges. 
Expressions are implicitly squared and summed over all domains since our solver is for non-linear least squared problems. Energies are described per-pixel or per-edge with, e.g. `Angle(0,0)`, as the centered pixel. Other constant offsets can be given to select neighbors.

To access values at graph locations you use the name of the vertex as the index into the array:

    N = Dim("N",0)
    local Angle = Unknown("Angle", float3,{N},0)		
    local G =  Graph("G", 1, "head", {N}, 2,
                             "tail", {N}, 3)  

    value = Angle(G.head)
    value2 = Angle(G.tail)
    
### Math Operators ###

Generic math operators are usable on any value or vector:

    +
    -
    *
    /
    abs
    acos
    acosh
    and_
    asin
    asinh
    atan
    atan2
    classes
    cos
    cosh
    div
    eq
    exp
    greater
    greatereq
    less
    lesseq
    log
    log10
    mul
    not_
    or_
    pow
    prod
    sin
    sinh
    sqrt
    tan
    tanh
    Select(condition,truevalue,falsevalue) -- piecewise conditional operator, if condition ~= 0, it is truevalue, otherwise it is falsevalue
    scalar = All(vector) -- true if all values in the vector are true
    scalar = Any(vector) -- true of any value in the vector is true

All operators apply elementwise to `Vector` objects.

Because Lua does not allow generic overloading of comparison ( `==` , '<=', ... ), you must use the functions we have provided instead for comparisions:
`eq(a,b)`, `lesseq(a,b)`, etc.


### Defining Energies ###

    `Energy(energy1,energy2,...)`
    
Add the terms `energy1`, ... to the energy of the whole problem. Energy terms are implicitly squared and summed over the entire domain (array or graph) on which they are defined.  Each channel of a `Vector` passed as an energy is treated as a separate energy term.


### Boundaries ###

For energies defined on arrays, it is possible to control how the energy behaves on the boundaries.  Any energy term has a particular pattern of data it reads from neighboring pixels in the arrays, which we call its `stencil`. By default, residual values are only defined for pixels in the array where the whole stencil has defined values. For a 3x3 stencil, for instance, this means that the 1-pixel border of an image will not evaluate this energy term (or equivalently, this term contributes 0 to the overall energy).

If you do not want the default behavior, you can use the `InBounds(x,y)` functions along with the `Select` function to describe custom behavior:

    customvalue = Select(InBounds(1,0),value_in_bounds,value_on_the_border) 

`InBounds` is true only when the relative offet `(1,0)` is in-bounds for the centered pixel. Any energy that uses `InBounds` will be evaluated at _every_ pixel including the border region, and it is up to the user to choose what to do about boundaries.

### Vectors ###

    vector = Vector(a,b,c)
    vector2 = vector:dot(vector)
    scalar = vector:sum()
    numelements = vector:size() -- 3 for this vector
    vector3 = vector + vector -- elementwise addition

Objects of type `float2`, `float3` ... are vectors. The function `Vector` constructs them from individual elements. All math is done elementwise to vectors, including functions like `abs`.

### Binding Values for the C/C++ API ###

To connect values passed in from C/C++ API to values in the energy specification, the functions  `Array`, `Unknown`, `Dim`, and `Graph` have an argument (e.g., `problemparams_position`) that binds the object in the energy specification to the argument at that numeric offset in the parameters passed to Opt. 

API Example:

    uint32_t dims[] = { width, height };
	Plan * m_plan = Opt_ProblemPlan(m_optimizerState, m_problem, dims);
	
Energy Specification:

    local W,H = Dim("W",0), Dim("H",1)
    
API Example:

	void* solverParams[] = { &nNonLinearIterations, &nLinearIterations };
	float weightFitSqrt = sqrt(weightFit);
	float weightRegSqrt = sqrt(weightReg);
	
	float * d_x = ... //raw image data for x in (H,W,channel) order
	float * d_a = ...
	float * d_urshape = ...
	float * d_constraints = ...
	float * d_mask = ...
	
	void* problemParams[] = { d_x, d_a, d_urshape, d_constraints, d_mask, &weightFitSqrt, &weightRegSqrt };
		
	Opt_ProblemSolve(m_optimizerState, m_plan, problemParams, solverParams);
    
Energy Specification:
    
    local Offset = Unknown("Offset",float2,{W,H},0)
    local Angle = Unknown("Angle",float,{W,H},1)
    local UrShape = 	Array("UrShape", float2,{W,H},2)		
    local Constraints = Array("Constraints", float2,{W,H},3)	
    local Mask = 		Array("Mask", float, {W,H},4)	
    local w_fitSqrt = Param("w_fitSqrt", float, 5)
    local w_regSqrt = Param("w_regSqrt", float, 6)


Solver Parameters
=================

The 'gaussNewtonGPU' solver takes two solver parameters passed in as an array of pointers:

parameter 0: the number of non-linear iterations
parameter 1: the number of linear iterations in each non-linear step

    int nonlinear = 2;
    int linear = 10;
    void * solverparams[] = { &nonlinear, linear};