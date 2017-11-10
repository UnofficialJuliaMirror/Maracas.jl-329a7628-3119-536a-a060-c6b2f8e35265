module Maracas
export describe, test, it, @test, @test_throws
import Compat.Test: AbstractTestSet, record, finish, get_testset_depth, get_testset, Broken, Pass, Fail, Error, TestSetException
import Base.+
using Compat.Test
if VERSION < v"0.6"
    print_with_color(args...;kwargs...) = Base.print_with_color(args...)
    TestSetException(pass::Int64, fail::Int64, error::Int64, broken::Int64, errors_and_fails::Array{Any,1}) = Base.Test.TestSetException(pass, fail, error, broken)
    error_color() = :red
else
    error_color() = Base.error_color()
end

# Backtrace utility functions
function ip_matches_func_and_name(ip, func::Symbol, dir::String, file::String)
    for fr in StackTraces.lookup(ip)
        if fr === StackTraces.UNKNOWN || fr.from_c
            return false
        end
        path = string(fr.file)
        fr.func == func && dirname(path) == dir && basename(path) == file && return true
    end
    return false
end
function scrub_backtrace(bt)
    do_test_ind = findfirst(addr->ip_matches_func_and_name(addr, :do_test, ".", "test.jl"), bt)
    if do_test_ind != 0 && length(bt) > do_test_ind
        bt = bt[do_test_ind + 1:end]
    end
    name_ind = findfirst(addr->ip_matches_func_and_name(addr, Symbol("macro expansion"), ".", "test.jl"), bt)
    if name_ind != 0 && length(bt) != 0
        bt = bt[1:name_ind]
    end
    return bt
end

"""
    MaracasTestSet
"""
type MaracasTestSet <: AbstractTestSet
    description::AbstractString
    results::Vector
    n_passed::Int
    anynonpass::Bool
end
MaracasTestSet(desc) = MaracasTestSet(desc, [], 0, false)

# For a broken result, simply store the result
record(ts::MaracasTestSet, t::Broken) = (push!(ts.results, t); t)
# For a passed result, do not store the result since it uses a lot of memory
record(ts::MaracasTestSet, t::Pass) = (ts.n_passed += 1; t)
# For the other result types, immediately print the error message
# but do not terminate. Print a backtrace.
function record(ts::MaracasTestSet, t::Union{Fail, Error})
    if myid() == 1
        print_with_color(:white, ts.description, ": ")
        print(t)
        # don't print the backtrace for Errors because it gets printed in the show
        # method
        isa(t, Error) || Base.show_backtrace(STDOUT, scrub_backtrace(backtrace()))
        println()
    end
    push!(ts.results, t)
    t, isa(t, Error) || backtrace()
end

record(ts::MaracasTestSet, t::AbstractTestSet) = push!(ts.results, t)

function print_test_errors(ts::MaracasTestSet)
    for t in ts.results
        if (isa(t, Error) || isa(t, Fail)) && myid() == 1
            println("Error in testset $(ts.description):")
            Base.show(STDOUT,t)
            println()
        elseif isa(t, MaracasTestSet)
            print_test_errors(t)
        end
    end
end


function print_test_results(ts::MaracasTestSet, depth_pad=0)
    results_count = ResultsCount(ts)
    align = max(get_alignment(ts, 0), length("Test Summary:"))
    # Print the outer test set header once
    pad = total(results_count) == 0 ? "" : " "
    print_with_color(:white, rpad("Test Summary:",align-10," "), " |", pad; bold = true)

    print_passes_result(results_count)
    print_fails_result(results_count)
    print_errors_result(results_count)
    print_broken_result(results_count)
    print_total_result(results_count)
    println()
    # Recursively print a summary at every level
    print_counts(ts, depth_pad, align, results_count, HeadersWidth(results_count))
end


const TESTSET_PRINT_ENABLE = Ref(true)

# Called at the end of a @testset, behaviour depends on whether
# this is a child of another testset, or the "root" testset
function finish(ts::MaracasTestSet)
    # If we are a nested test set, do not print a full summary
    # now - let the parent test set do the printing
    if get_testset_depth() != 0
        # Attach this test set to the parent test set
        parent_ts = get_testset()
        record(parent_ts, ts)
        return ts
    end
    total_pass, total_fail, total_error, total_broken, total = tuple(ResultsCount(ts))

    if TESTSET_PRINT_ENABLE[]
        print_test_results(ts)
    end

    # Finally throw an error as we are the outermost test set
    if total != total_pass + total_broken
        # Get all the error/failures and bring them along for the ride
        efs = filter_errors(ts)
        throw(TestSetException(total_pass,total_fail,total_error, total_broken, efs))
    end

    # return the testset so it is returned from the @testset macro
    ts
end

# Recursive function that finds the column that the result counts
# can begin at by taking into account the width of the descriptions
# and the amount of indentation. If a test set had no failures, and
# no failures in child test sets, there is no need to include those
# in calculating the alignment
function get_alignment(ts::MaracasTestSet, depth::Int)
    # The minimum width at this depth is
    ts_width = 2*depth + length(ts.description)
    # Return the maximum of this width and the minimum width
    # for all children (if they exist)
    isempty(ts.results) && return ts_width
    child_widths = map(t->get_alignment(t, depth+1), ts.results)
    return max(ts_width, maximum(child_widths))
end
get_alignment(ts, depth::Int) = 0

# Recursive function that fetches backtraces for any and all errors
# or failures the testset and its children encountered
function filter_errors(ts::MaracasTestSet)
    efs = []
    for t in ts.results
        if isa(t, MaracasTestSet)
            append!(efs, filter_errors(t))
        elseif isa(t, Union{Fail, Error})
            append!(efs, [t])
        end
    end
    efs
end

hwidth(header, total) = total > 0 ? max(length(header), ndigits(total)) : 0

type ResultsCount
    passes::Int
    fails::Int
    errors::Int
    broken::Int
end
type HeadersWidth
    passes::Int
    fails::Int
    errors::Int
    broken::Int
    total::Int
    function HeadersWidth(results::ResultsCount)
        pass_width   = hwidth("Pass", results.passes)
        fail_width   = hwidth("Fail", results.fails)
        error_width  = hwidth("Error", results.errors)
        broken_width = hwidth("Broken", results.broken)
        total_width  = hwidth("Total", total(results))
        new(pass_width, fail_width, error_width, broken_width, total_width)
    end
end

total(count::ResultsCount) = count.passes + count.fails + count.errors + count.broken
has_failed(count::ResultsCount) = (count.fails + count.errors > 0)
+(a::ResultsCount, b::ResultsCount) = ResultsCount(a.passes + b.passes, a.fails + b.fails, a.errors + b.errors, a.broken + b.broken)
+(a::ResultsCount, b::Fail) = ResultsCount(a.passes, a.fails + 1, a.errors, a.broken)
+(a::ResultsCount, b::Error) = ResultsCount(a.passes, a.fails, a.errors + 1, a.broken)
+(a::ResultsCount, b::Broken) = ResultsCount(a.passes, a.fails, a.errors, a.broken + 1)
+(a::ResultsCount, b::AbstractTestSet) = (a + ResultsCount(b))
tuple(results_count::ResultsCount) = (results_count.passes, results_count.fails, results_count.errors, results_count.broken, total(results_count))

function ResultsCount(ts::MaracasTestSet)
    results_count = ResultsCount(ts.n_passed, 0, 0, 0)
    for t in ts.results
        results_count += t
    end
    ts.anynonpass = has_failed(results_count)
    return results_count
end
passes_result(result::ResultsCount) = lpad("Pass", max(length("Pass"), ndigits(result.passes))," ")
ResultsCount(ts) = nothing

function print_passes_result(result::ResultsCount)
    if result.passes > 0
        print_with_color(:green, passes_result(result), "  "; bold = true)
    end
end

fails_result(result::ResultsCount) = lpad("Fail", max(length("Fail"), ndigits(result.fails))," ")
function print_fails_result(result::ResultsCount)
    if result.fails > 0
        print_with_color(error_color(), fails_result(result), "  "; bold = true)
    end
end

errors_result(result::ResultsCount) = lpad("Error", max(length("Error"), ndigits(result.errors))," ")
function print_errors_result(result::ResultsCount)
    if result.errors > 0
        print_with_color(error_color(), errors_result(result), "  "; bold = true)
    end
end

broken_result(result::ResultsCount) = lpad("Broken", max(length("Broken"), ndigits(result.broken))," ")
function print_broken_result(result::ResultsCount)
    if result.broken > 0
        print_with_color(Base.warn_color(), broken_result(result), "  "; bold = true)
    end
end

total_result(result::ResultsCount) = lpad("Total", max(length("Total"), ndigits(total(result)))," ")
function print_total_result(result::ResultsCount)
    if total(result) > 0
        print_with_color(Base.info_color(), total_result(result); bold = true)
    end
end

function print_result_column(color, result, width)
    if result > 0
        print_with_color(color, lpad(string(result), width, " "), "  ")
    elseif width > 0
        print(lpad(" ", width), "  ")
    end
end
# Recursive function that prints out the results at each level of
# the tree of test sets
function print_counts(ts::MaracasTestSet, depth, align, results_count::ResultsCount, headers_width)
    passes, fails, errors, broken, subtotal = tuple(results_count)

    print(rpad(string("  "^depth, ts.description), align, " "), " | ")

    print_result_column(:green, passes, headers_width.passes)
    print_result_column(error_color(), fails, headers_width.fails)
    print_result_column(error_color(), errors, headers_width.errors)
    print_result_column(Base.warn_color(), broken, headers_width.broken)

    if subtotal == 0
        print_with_color(Base.info_color(), "No tests")
    else
        print_with_color(Base.info_color(), lpad(string(subtotal), headers_width.total, " "))
    end
    println()

    for t in ts.results
        print_counts(t, depth + 1, align, ResultsCount(t), headers_width)
    end
end
print_counts(args...) = nothing

const default_color = Base.text_colors[:normal]
function describe(fn::Function, text)
    text = string(Base.text_colors[:yellow], Base.text_colors[:bold], text, default_color, )
    @testset MaracasTestSet "$text" begin
        fn()
    end
end
function it(fn::Function, text)
    text = string(Base.text_colors[:cyan], Base.text_colors[:bold], "[Spec] ", default_color, "it ", text)
    @testset MaracasTestSet "$text" begin
        fn()
    end
end
function test(fn::Function, text)
    text = string(Base.text_colors[:blue], Base.text_colors[:bold], "[Test] ", default_color, text)
    @testset MaracasTestSet "$text" begin
        fn()
    end
end


end
