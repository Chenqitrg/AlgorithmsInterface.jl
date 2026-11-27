using AlgorithmsInterface
using AlgorithmsInterface: AlgorithmTreeError, TreeInputError, TreeLayoutError,
    TreeFieldError, TreeExpressionError, TreeConstructorError
using Test
using Dates: Dates, Minute

# Re-evaluating a displayed tree resolves its qualified constructor names.
# Give the fixtures a stable path instead of ParallelTestRunner's anonymous module.
@eval Main module AlgorithmTreeFixtures
using AlgorithmsInterface
using Dates: Minute

# No keyword constructor: exercises positional construction and type inference.
struct Leaf{T} <: Algorithm
    value::T
end
struct Empty <: Algorithm end

# Keyword defaults and validation must still run when construction uses a tree.
struct Solver{A, S} <: Algorithm
    inner::A
    stopping_criterion::S
    steps::Int
end
function Solver(;
        inner::A = Leaf(1), stopping_criterion::S = StopAfterIteration(10),
        steps::Int = 2
    )::Solver{A, S} where {A, S}
    steps > 0 || throw(DomainError(steps))
    return Solver(inner, stopping_criterion, steps)
end

function keyword_tree(value::T, steps::Int)::Solver where {T}
    return @algorithm """
    Solver
      inner: Leaf
        value: value
      steps: steps
    """
end

function local_constructor_tree(constructor::Type{A}, value::T)::Algorithm where {A, T}
    return @algorithm """
    constructor
      value: value
    """
end

# Complete nested example used by the inference checks below. Both algorithms
# have their own stopping criteria, and the outer criterion combines two limits.
struct Inner{S <: StoppingCriterion} <: Algorithm
    step_size::Float64
    stopping_criterion::S
end

struct Outer{A <: Algorithm, S <: StoppingCriterion} <: Algorithm
    inner::A
    stopping_criterion::S
end

function make_algorithm(step_size::Float64, inner_limit::Int)::Outer
    return @algorithm """
    Outer
    ├─ inner: Inner
    │  ├─ step_size: step_size
    │  └─ stopping_criterion: StopAfterIteration
    │     └─ max_iterations: inner_limit
    └─ stopping_criterion: StopWhenAny
       └─ criteria: (StopAfterIteration(100), StopAfter(Minute(1)))
    """
end

# Mutable solely so display can be tested against a self-reference.
mutable struct Cycle <: Algorithm
    child::Any
end
end

using Main: AlgorithmTreeFixtures
const TreeFixtures = AlgorithmTreeFixtures

@testset "tree construction and display inference" begin
    # Use runtime arguments: literal-only examples can hide inference problems
    # through constant folding. @inferred checks the full concrete return type.
    algorithm = @inferred TreeFixtures.make_algorithm(0.1, 10)
    @test algorithm.inner.step_size == 0.1
    @test algorithm.inner.stopping_criterion.max_iterations == 10
    @test (@inferred AlgorithmsInterface.algorithmtree(algorithm)) isa String
    @test (@inferred show(IOBuffer(), MIME"text/plain"(), algorithm)) === nothing

    # Also check the keyword-constructor path with defaults and generic leaf types.
    for value in (1, 0.1, "value")
        configured = @inferred TreeFixtures.keyword_tree(value, 3)
        @test configured.inner.value === value
        @test configured.steps == 3
    end
end

@testset "tree input" begin
    @testset "Unicode branches evaluate leaves once, in source order" begin
        calls = Int[]

        function record_call(i::Int)::Int
            push!(calls, i)
            return i
        end

        algorithm = @algorithm """
        TreeFixtures.Solver
        ├─ inner: TreeFixtures.Leaf
        │  └─ value: record_call(1)
        ├─ stopping_criterion: StopAfterIteration
        │  └─ max_iterations: record_call(2)
        └─ steps: record_call(3)
        """

        @test algorithm.inner.value == 1
        @test algorithm.stopping_criterion.max_iterations == 2
        @test algorithm.steps == 3

        # Checking values alone would miss duplicate or reordered evaluations.
        @test calls == [1, 2, 3]
    end

    @testset "Indented leaves use caller scope without capturing local names" begin
        let value = "x:y", constructor = :shadow, kwargs = :shadow
            algorithm = @algorithm """
            TreeFixtures.Leaf
              value: value
            """
            @test algorithm.value == "x:y"
        end
    end

    @testset "Constructors retain defaults, explicit types and validation" begin
        @test (@algorithm "TreeFixtures.Solver").steps == 2
        @test (@algorithm "TreeFixtures.Empty") isa TreeFixtures.Empty
        @test (@algorithm "TreeFixtures.Leaf{Int}\n  value: 7").value === 7

        # The keyword constructor's own error must propagate, not trigger a fallback.
        @test_throws DomainError (@algorithm "TreeFixtures.Solver\n  steps: -1")
        @test_throws TreeFieldError (@algorithm "TreeFixtures.Leaf\n  wrong: 1")
        @test_throws TreeConstructorError (@algorithm "Int\n  value: 1")
        @test_throws TreeConstructorError (@algorithm "1")
        @test_throws TreeConstructorError (@algorithm "StopAfterIteration\n  max_iterations: 1")

        # A failure in caller code is not a tree syntax or construction error.
        @test_throws DivideError (@algorithm "TreeFixtures.Leaf\n  value: div(1, 0)")
    end

    @testset "Leaf expressions are not mistaken for tree structure" begin
        # A connector inside a string must not select Unicode-tree parsing.
        @test (@algorithm "TreeFixtures.Leaf\n  value: \"└─ text\"").value == "└─ text"

        # A leaf can construct an object directly instead of opening another branch.
        algorithm = @algorithm """
        TreeFixtures.Solver
          steps: 4
          inner: TreeFixtures.Empty()
        """
        @test algorithm.inner isa TreeFixtures.Empty
    end
end

@testset "malformed tree input" begin
    # Expand only: these are syntax errors and must fail before any constructor runs.
    # Named cases make failures explain the rejected rule rather than just a string.
    cases = (
        ("empty tree", TreeInputError, 1, ""),
        ("skipped parent level", TreeLayoutError, 2, "TreeFixtures.Leaf\n    value: 1"),
        ("tab indentation", TreeLayoutError, 2, "TreeFixtures.Leaf\n\tvalue: 1"),
        ("duplicate field", TreeFieldError, 3, "TreeFixtures.Leaf\n  value: 1\n  value: 2"),
        ("missing field separator", TreeFieldError, 2, "TreeFixtures.Leaf\n  value 1"),
        ("missing leaf value", TreeFieldError, 2, "TreeFixtures.Leaf\n  value:"),
        ("invalid field identifier", TreeFieldError, 2, "TreeFixtures.Leaf\n  bad name: 1"),
        ("multiple leaf expressions", TreeExpressionError, 2, "TreeFixtures.Leaf\n  value: 1; 2"),
        ("incomplete leaf expression", TreeExpressionError, 2, "TreeFixtures.Leaf\n  value: ("),
        ("last child uses a continuing connector", TreeLayoutError, 2, "TreeFixtures.Leaf\n├─ value: 1"),
        ("connector is missing its following space", TreeLayoutError, 2, "TreeFixtures.Leaf\n└─value: 1"),
        (
            "ancestor column is too short", TreeLayoutError, 3, """
            TreeFixtures.Solver
            ├─ inner: TreeFixtures.Leaf
            │ └─ value: 1
            └─ steps: 2
            """,
        ),
        (
            "ancestor continuation is missing", TreeLayoutError, 3, """
            TreeFixtures.Solver
            ├─ inner: TreeFixtures.Leaf
               └─ value: 1
            └─ steps: 2
            """,
        ),
    )
    # The parser owns all text validation; macro expansion must expose the same
    # errors without evaluating names, leaf expressions, or constructors.
    for (description, error_type, line, text) in cases, phase in (:parser, :macro)
        @testset "$description ($phase)" begin
            caught = try
                if phase === :parser
                    AlgorithmsInterface._parse_algorithm_tree(text)
                else
                    macroexpand(@__MODULE__, Expr(:macrocall, Symbol("@algorithm"), LineNumberNode(1), text))
                end
                nothing
            catch err
                err
            end

            @test caught isa error_type
            @test caught isa AlgorithmTreeError
            if caught isa AlgorithmTreeError
                @test caught.line == line
                @test occursin("line $line", sprint(showerror, caught))
            end
        end
    end
    @testset "Input must be a literal string" begin
        @test_throws TreeInputError AlgorithmsInterface._parse_algorithm_tree(:variable)
        @test_throws TreeInputError macroexpand(@__MODULE__, :(@algorithm variable))
    end
end

@testset "macro expansion versus runtime validation" begin
    # Parsing and layout validation return concrete types even though individual
    # Julia syntax values can be expressions, symbols, or literals.
    tree = @inferred AlgorithmsInterface._parse_algorithm_tree("TreeFixtures.Leaf\n  value: 7")
    @test tree.children[1].value === 7
    @test (@inferred AlgorithmsInterface._validate_tree_layout(tree)) === nothing

    # Expanding a function rejects malformed tree syntax before the function runs.
    definition = :(
        function invalid_tree(value::Int)::Algorithm
            @algorithm "TreeFixtures.Leaf\n  value: ("
        end
    )
    @test_throws TreeExpressionError macroexpand(@__MODULE__, definition)

    # Names and calls remain unevaluated during expansion. Resolving them here
    # would reject valid local constructors or execute caller code prematurely.
    expression = :(@algorithm "constructor\n  value: error(\"runtime only\")")
    @test macroexpand(@__MODULE__, expression) isa Expr

    algorithm = @inferred TreeFixtures.local_constructor_tree(TreeFixtures.Leaf{Int}, 7)
    @test algorithm.value === 7
    @test_throws TreeConstructorError TreeFixtures.local_constructor_tree(Int, 7)
end

@testset "tree error rendering and runtime locations" begin
    @test sprint(showerror, TreeInputError("expected a literal string", nothing)) ==
        "TreeInputError: algorithm tree: expected a literal string"

    caught = try
        @algorithm """
        TreeFixtures.Solver
          inner: Int
            value: 1
        """
    catch err
        err
    end
    @test caught isa TreeConstructorError
    @test caught.line == 2
    @test (@inferred showerror(IOBuffer(), caught)) === nothing
end

@testset "tree display behavior" begin
    original = TreeFixtures.Solver()

    @testset "Plain-text display uses the Unicode tree" begin
        tree = sprint(show, MIME"text/plain"(), original)
        @test tree == AlgorithmsInterface.algorithmtree(original)
        @test occursin("│  └─ value:", tree)
        @test_throws ArgumentError AlgorithmsInterface.algorithmtree(original; style = :bad)
    end

    @testset "Compact contexts retain ordinary Julia printing" begin
        compact_plain = sprint(show, MIME"text/plain"(), original; context = :compact => true)
        compact_show = sprint(show, original; context = :compact => true)
        @test compact_plain == compact_show
        @test !occursin('\n', repr([original]))
    end

    @testset "Cycles terminate, but shared children are not cycles" begin
        cycle = TreeFixtures.Cycle(nothing)
        cycle.child = cycle
        @test occursin("<cycle>", sprint(show, MIME"text/plain"(), cycle))

        # Visiting the same child on two separate branches must remain valid.
        shared = TreeFixtures.Leaf(2)
        shared_algorithm = TreeFixtures.Solver(shared, shared, 2)
        tree = AlgorithmsInterface.algorithmtree(shared_algorithm)
        @test !occursin("<cycle>", tree)

    end
end

@testset "nested tree display in both styles" begin
    # Build the object with ordinary constructors. These checks need no input macro.
    algorithm = TreeFixtures.Outer(
        TreeFixtures.Inner(0.1, StopAfterIteration(10)), StopAfterIteration(20)
    )
    unicode_tree = """
    Main.AlgorithmTreeFixtures.Outer
    ├─ inner: Main.AlgorithmTreeFixtures.Inner
    │  ├─ step_size: 0.1
    │  └─ stopping_criterion: AlgorithmsInterface.StopAfterIteration
    │     └─ max_iterations: 10
    └─ stopping_criterion: AlgorithmsInterface.StopAfterIteration
       └─ max_iterations: 20
    """
    indented_tree = """
    Main.AlgorithmTreeFixtures.Outer
      inner: Main.AlgorithmTreeFixtures.Inner
        step_size: 0.1
        stopping_criterion: AlgorithmsInterface.StopAfterIteration
          max_iterations: 10
      stopping_criterion: AlgorithmsInterface.StopAfterIteration
        max_iterations: 20
    """
    @test (@inferred AlgorithmsInterface.algorithmtree(algorithm)) == chomp(unicode_tree)
    @test (@inferred AlgorithmsInterface.algorithmtree(algorithm; style = :indent)) == chomp(indented_tree)
    @test (@inferred show(IOBuffer(), MIME"text/plain"(), algorithm)) === nothing
    @test AlgorithmsInterface.algorithmtree(TreeFixtures.Empty()) == "Main.AlgorithmTreeFixtures.Empty"
end
