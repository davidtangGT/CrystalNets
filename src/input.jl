## Functions to handle input files.

using Chemfiles

include("clustering.jl")


"""
    parse_cif(file_path)

Parse a CIF file and return a dictionary where each identifier (without the
starting '_' character) is linked to its value.
Values are either a string or a vector of string (if defined in a loop).
"""
function parse_cif(file)
    all_data = Dict{String, Union{String, Vector{String}}}()
    inloop = false
    loopisspecified = false
    loopspec = String[]
    loop_n = 0

    l = read(file, String)
    i, j, x = nextword(l, 0)
    while i != 0

        if inloop
            if !loopisspecified
                if l[i] != '_' # This indicates the start of the values
                    loop_n = length(loopspec)
                    loopisspecified = true
                else # The identifier is part of the loop specification
                    push!(loopspec, l[i+1:j])
                    all_data[l[i+1:j]] = String[]
                    i, j, x = nextword(l, x); continue
                end
            end

            # From this point, the loop has been specified
            @assert loopisspecified
            if l[i] != '_' && l[i:j] != "loop_"
                for k in 1:loop_n
                    push!(all_data[loopspec[k]], l[i:j])
                    i, j, x = nextword(l, x)
                end
                continue
            end
            if l[i:j] == "loop_"
                loopisspecified = false
                loopspec = String[]
                i, j, x = nextword(l, x); continue
            end

            # This point can only be reached if we just quitted a loop
            inloop = false
        end

        @assert !inloop
        if l[i] == '_' # Simple identifier definition
            next_i, next_j, next_x = nextword(l, x)
            @assert next_i != 0
            all_data[l[i+1:j]] = l[next_i:next_j]
            x = next_x
        else
            if l[i:j] == "loop_"
                inloop = true
                loopisspecified = false
                loopspec = String[]
            elseif j-i > 4 && l[i:i+4] == "data_"
                @assert !haskey(all_data, "data")
                all_data["data"] = l[i+5:j]
            else
                k::Int = findprev(isequal('\n'), l, i)
                n::Int = count("\n", l[1:k])
                error("Unkown word \"$(l[i:j])\" at line $(n+1), position $(i-k):$(j-k)")
            end
        end

        i, j, x = nextword(l, x)
    end

    return all_data
end

function parsestrip(s)
    s = s[end] == ')' ? s[1:prevind(s, findlast('(', s))] : s
    return parse(BigFloat, s)
end


"""
    CIF(file_path::AbstractString)

Make a CIF object out of the parsed file.
"""
CIF(file::AbstractString) = CIF(parse_cif(file))
function CIF(parsed::Dict{String, Union{Vector{String},String}})
    natoms = length(parsed["atom_site_label"])
    equivalentpositions = pop!(parsed,
        haskey(parsed, "symmetry_equiv_pos_as_xyz") ?
            "symmetry_equiv_pos_as_xyz" : "space_group_symop_operation_xyz")
    refid = find_refid(equivalentpositions)
    cell = Cell(Symbol(haskey(parsed, "symmetry_cell_setting") ?
                            pop!(parsed, "symmetry_cell_setting") : ""),
                pop!(parsed, "symmetry_space_group_name_H-M"),
                haskey(parsed, "symmetry_Int_Tables_number") ?
                    parse(Int, pop!(parsed, "symmetry_Int_Tables_number")) : 0,
                parsestrip(pop!(parsed, "cell_length_a")),
                parsestrip(pop!(parsed, "cell_length_b")),
                parsestrip(pop!(parsed, "cell_length_c")),
                parsestrip(pop!(parsed, "cell_angle_alpha")),
                parsestrip(pop!(parsed, "cell_angle_beta")),
                parsestrip(pop!(parsed, "cell_angle_gamma")),
                parse.(EquivalentPosition, equivalentpositions, Ref(refid)))

    haskey(parsed, "symmetry_equiv_pos_site_id") && pop!(parsed, "symmetry_equiv_pos_site_id")
    removed_identity = false
    for i in eachindex(cell.equivalents)
        eq = cell.equivalents[i]
        if isone(eq.mat) && iszero(eq.ofs)
            deleteat!(cell.equivalents, i)
            removed_identity = true
            break
        end
    end
    @assert removed_identity

    labels =  pop!(parsed, "atom_site_label")
    _symbols = haskey(parsed, "atom_site_type_symbol") ?
                    pop!(parsed, "atom_site_type_symbol") : copy(labels)
    symbols = String[]
    @inbounds for x in _symbols
        i = findfirst(!isletter, x)
        push!(symbols, isnothing(i) ? x : x[1:i-1])
    end
    pos_x = pop!(parsed, "atom_site_fract_x")
    pos_y = pop!(parsed, "atom_site_fract_y")
    pos_z = pop!(parsed, "atom_site_fract_z")


    types = Symbol[]
    pos = Matrix{Float64}(undef, 3, natoms)
    correspondence = Dict{String, Int}()
    for i in 1:natoms
        @assert !haskey(correspondence, labels[i])
        correspondence[labels[i]] = i
        push!(types, Symbol(symbols[i]))
        pos[:,i] = parsestrip.([pos_x[i], pos_y[i], pos_z[i]])
        pos[:,i] .-= floor.(Int, pos[:,i])
    end

    invids = sortperm(types)
    types = types[invids]
    ids = invperm(invids)
    bonds = falses(natoms, natoms)
    if haskey(parsed, "geom_bond_atom_site_label_1") &&
       haskey(parsed, "geom_bond_atom_site_label_2")
        bond_a = pop!(parsed, "geom_bond_atom_site_label_1")
        bond_b = pop!(parsed, "geom_bond_atom_site_label_2")
        for i in 1:length(bond_a)
            x = correspondence[bond_a[i]]
            y = correspondence[bond_b[i]]
            bonds[x,y] = bonds[y,x] = 1
        end
    end

    return CIF(parsed, cell, ids, types, pos, bonds)
end



"""
    parse_arc(file)

Parse a .arc Systre archive such as the one used by the RCSR.
Return a pair `(flag, pairs)`.

`flag` is set if the archive corresponds to one generated by a compatible release
of CrystalNets. If unset, the genomes of the archive may not be the same as those
computed by CrystalNets for the same nets.
`pairs` is a `Dict{String,String}` whose entries have the form `genome => id` where `id`
is the name of the net and `genome` is the topological genome corresponding to this net
(given as a string of whitespace-separated values parseable by `PeriodicGraph`).
"""
function parse_arc(file)
    pairs = Dict{String,String}()
    curr_key = ""
    counter = 1
    firstline = readline(file)
    flag = startswith(firstline, "Made by CrystalNets.jl v")
    if flag
        flag = CRYSTAL_NETS_VERSION == VersionNumber(firstline[25:end])
    end
    for l in eachline(file)
        if length(l) > 3 && l[1:3] == "key"
            @assert isempty(curr_key)
            i = 4
            while isspace(l[i])
                i += 1
            end
            curr_key = l[i:end]
            @assert !haskey(pairs, curr_key)
        elseif length(l) > 2 && l[1:2] == "id"
            @assert !isempty(curr_key)
            i = 3
            while isspace(l[i])
                i += 1
            end
            pairs[curr_key] = l[i:end]
            curr_key = ""
        end
    end
    return flag, pairs
end

"""
    parse_arcs(file)

Parse a folder containing .arc Systre archives such as the one used by the RCSR.
Return a pair `(flag, pairs)` with the same convention than `parse_arc`
"""
function parse_arcs(path)
    combine(x, y) = x * ", " * y
    dict = Dict{String,String}()
    flag = true
    for f in readdir(path; sort=true)
        _flag, _dict = parse_arc(path*f)
        flag &= _flag
        mergewith!(combine, dict, _dict)
    end
    return flag, dict
end

function parse_atom_name(name::AbstractString)
    firstsep = findfirst(x -> ispunct(x) || isspace(x) || isnumeric(x), name)
    if firstsep isa Nothing
        return String(name)
    else
        firstsep::Int
        if firstsep != 1 && !any(isuppercase, @view name[nextind(name, firstsep):end])
            return String(name[1:prevind(firstsep)])
        else
            return String(name)
        end
    end
end

function parse_atom(name)
    atom = Chemfiles.Atom(name)
    set_type!(atom, parse_atom_name(name))
    return atom
end


function set_unique_bond_type!(frame::Frame, types, bond_length, bonded_atoms::Tuple{Symbol, Symbol}, onlykeep, tol)
    @ifwarn @info "To avoid guessing bonds, use a file format that contains the bonds."
    n = Int(size(frame))
    pos = Chemfiles.positions(frame)
    mat = Chemfiles.matrix(UnitCell(frame))'
    indices = [i for i in 1:n if types[i] ??? onlykeep]
    #=@inbounds=# for _i in 1:length(indices)
        i = indices[_i]
        for _j in _i+1:length(indices)
            j = indices[_j]
            if minmax(types[i], types[j]) == bonded_atoms
                bonded = abs2(periodic_distance(pos[:,i], pos[:,j], mat) - bond_length) <= tol
                if bonded
                    Chemfiles.add_bond!(frame, i-1, j-1)
                end
            end
        end
    end
    nothing
end

function try_guess_bonds!(frame::Frame)
    # n = Int(size(frame))
    # types = Vector{Symbol}(undef, n)
    # for i in 1:n
    #     types[i] = Symbol(parse_atom_name(Chemfiles.type(Chemfiles.Atom(frame, i-1))))
    # end
    # unique_types = unique!(sort(types))
    # if unique_types == [:C] || unique_types == [:C, :H]
    #     if !(NOWARN::Bool)
    #         @warn "Guessing bonds. The structure seems to be made of only carbons (and possibly hydrogens): using an interatomic distance of 1.54??0.3 ?? to assign edges between C atoms."
    #     end
    #     set_unique_bond_type!(frame, types, 1.54, (:C, :C), (:C,), 0.3)
    # elseif unique_types == [:O, :Si] || unique_types == [:Si]
    #     if !(NOWARN::Bool)
    #         @warn "Guessing bonds. The structure seems to be a zeolite: using an interatomic distance of 3.1??0.2 ?? to assign edges between Si atoms."
    #     end
    #     set_unique_bond_type!(frame, types, 1.63, (:O, :Si), (:O, :Si), 0.1)
    # else
        @ifwarn begin
            @warn "Guessing bonds through Chemfiles. This may take a while for big structures and may be inexact."
            @info "To avoid guessing bonds, use a file format that contains the bonds."
        end
        guess_bonds!(frame)
    # end
end


function attribute_residues(topology, assert_use_existing_residues)
    m = Int(count_residues(topology))
    n = Int(size(topology))
    atoms_in_residues = m == 0 ? 0 : sum(length(atoms(Residue(topology, i))) for i in 0:(m-1))
    @assert atoms_in_residues <= n

    if atoms_in_residues < n
        if assert_use_existing_residues
            throw(ArgumentError("""
            Cannot use existing residues as vertices because not all atoms have an associated residue.
            To fix this, either assign a residue to each atom or provide another way to detect the vertices.
            """))
        end
        @ifwarn begin
            if atoms_in_residues > 0
                @warn "Some but not all atoms have an associated residue, so we cannot rely on existing residues"
            end
        end
        attributions = Int[]
    else
        attributions = zeros(Int, n)
        for i_residue in 1:m
            for atom in atoms(Residue(topology, i_residue-1))
                attributions[atom+1] = i_residue
            end
        end
    end
    return attributions
end

@static if !isdefined(Chemfiles, :atoms) # up to 0.9.3 included
    function atoms(residue::Residue)
        count = size(residue)
        result = Array{UInt64}(undef, count)
        Chemfiles.__check(Chemfiles.lib.chfl_residue_atoms(Chemfiles.__const_ptr(residue), pointer(result), count))
        return result
    end
end


function check_collision(pos, mat)
    _n, n = size(pos)
    @assert _n == 3
    invmat = inv(mat)
    toremove = Int[]
    for i in 1:n, j in (i+1):n
        if periodic_distance(invmat*pos[:,i], invmat*pos[:,j], mat) < 0.55
            push!(toremove, i)
            push!(toremove, j)
        end
    end
    tokeep = collect(1:n)
    if !isempty(toremove)
        @ifwarn @warn "This file contains multiple colliding atoms. All colliding atoms will be removed."
        unique!(sort!(toremove))
    end
    return toremove
end


hasHneighbor(types, graph, i) = any(x -> types[x.v] === :H, neighbors(graph,i))
function check_valence(types, graph)
    n = length(types)

    ## Small atoms valence check
    invalidatoms = Set{Symbol}()
    for i in 1:n
        d = degree(graph, i)
        t = types[i]
        if t === :O && d > 2 && (d > 3 || !hasHneighbor(types, graph, i))
            push!(invalidatoms, :O)
        elseif t === :C && d > 4
            push!(invalidatoms, :C)
        elseif t === :N && d > 3 && (d > 4 || !hasHneighbor(types, graph, i))
            push!(invalidatoms, :N)
        end
    end
    if !isempty(invalidatoms)
        s = String.(collect(invalidatoms))
        @ifwarn @warn "Found $(join(s, ',', " and ")) with too many bonds."
        return true
    end
    return false
end


"""
    @enum BondingMode

Selection mode for the detection of bonds. The choices are:
-   `InputBonds`: use the input bonds. Fail if those are not specified.
-   `ChemfilesBonds`: use chemfiles built-in bond detection mechanism.
-   `AutoBonds`: if the input specifies bonds, use them unless they look suspicious (too or too
    large according to a heuristic). Otherwise, fall back to `ChemfilesBonds`.
"""
@enum BondingMode begin
    InputBonds
    ChemfilesBonds
    AutoBonds
end


function sanity_checks!(pos, types, graph, mat, bondingmode)
    ## Bond length check
    removeedges = PeriodicEdge3D[]
    for e in edges(graph)
        s, d = e.src, e.dst.v
        bondlength = norm(pos[:,d] .+ (mat * e.dst.ofs) .- pos[:,s])
        if bondlength > 3
            @ifwarn @warn "Suspiciously large bond found."
            return true
        elseif bondlength < 0.85 && types[s] !== :H && types[d] !== :H
            push!(removeedges, e)
        end
    end
    if bondingmode == AutoBonds
        @ifwarn begin
            if !isempty(removeedges)
                @warn "Suspiciously small bond found. Such bonds are probably spurious and will be deleted."
                @info "To force retaining these bonds, use --bond-detect=input or --bond-detect=chemfiles"
            end
        end
        for e in removeedges
            rem_edge!(graph, e)
        end
    end
    return false
end


"""
       parse_chemfiles(path)

Parse a file given in any reckognised chemical format and extract the topological
information.
Such format can be .cif or any file format reckognised by Chemfiles.jl that
contains all the necessary topological information.
"""
function parse_chemfile(_path, exportto=tempdir(), bondingmode::BondingMode=AutoBonds, assert_use_existing_residues=false ; ignore_atoms=[])
    # Separate the cases unhandled by Chemfiles from the others
    path = expanduser(_path)
    cell = Cell()
    frame::Frame = if lowercase(last(splitext(path))) == ".cif"
        framecif = Frame()
        cif = expand_symmetry(CIF(path))
        a, b, c, ??, ??, ?? = cell_parameters(cif.cell)
        set_cell!(framecif, UnitCell(a, b, c, ??, ??, ??))
        n = length(cif.ids)
        ignored = 0
        for i in 1:n
            typ = cif.types[cif.ids[i]]
            if typ ??? ignore_atoms
                ignored += 1
                continue
            end
            pos = cif.cell.mat * cif.pos[:,i]
            atom = parse_atom(string(typ))
            add_atom!(framecif, atom, Vector{Float64}(pos))
        end
        n -= ignored
        if iszero(cif.bonds)
            try_guess_bonds!(framecif)
        else
            for i in 1:n, j in (i+1):n
                if cif.bonds[i,j]
                    add_bond!(framecif, i-1, j-1)
                end
            end
        end
        attributions = Int[]

        framecif
    else # The rest is handled by Chemfiles

        frameelse = read(Trajectory(path))
        for i in Int(size(frameelse))-1:-1:0
            if Symbol(type(Chemfiles.Atom(frameelse, i))) ??? ignore_atoms
                Chemfiles.remove_atom!(frameelse, i)
            end
        end

        toremove = reverse(check_collision(positions(frameelse), matrix(UnitCell(frame))))
        for j in toremove
            Chemfiles.remove_atom!(frameelse, j-1)
        end

        topology = Topology(frameelse)
        n = Int(size(topology))

        if bonds_count(topology) == 0
            try_guess_bonds!(frameelse)
            topology = Topology(frameelse) # safer but useless since the underlying pointer is the same
        end

        attributions = attribute_residues(topology, assert_use_existing_residues)

        frameelse
    end

    cell = Cell(Cell(), SMatrix{3,3,BigFloat}(matrix(UnitCell(frame)))')
    if !all(isfinite, cell.mat) || iszero(det(cell.mat))
        @ifwarn @warn "Suspicious unit cell of matrix $(Float64.(cell.mat)). Is the input really periodic? Using a cubic unit cell instead"
        cell = Cell()
    end

    types = [Symbol(type(Chemfiles.Atom(frame, i))) for i in 0:(n-1)]
    poss = copy(positions(frame))

    adjacency = zeros(Bool, n, n)
    for (a,b) in eachcol(bonds(Topology(frame)))
        adjacency[a+1,b+1] = true
        adjacency[b+1,a+1] = true
    end
    mat = Float64.(cell.mat)
    graph = PeriodicGraph3D(n, edges_from_bonds(adjacency, mat, poss))

    if bondingmode != InputBonds
        bad_valence = check_valence(types, graph)
        recompute_bonds = bad_valence || sanity_checks!(poss, types, graph, mat, bondingmode)
        if recompute_bonds
            @ifwarn begin
                @warn "Disregarding all bonds from the input file."
                @info "To force retaining the initial bonds, use --bond-detect=input"
            end
            try_guess_bonds!(frame)
            topology = Topology(frame)
            adjacency = zeros(Bool, n, n)
            for (a,b) in eachcol(bonds(topology))
                adjacency[a+1,b+1] = true
                adjacency[b+1,a+1] = true
            end
            graph = PeriodicGraph3D(n, edges_from_bonds(adjacency, cell.mat, poss))
            @ifwarn if check_valence(types, graph)
                @warn "Remaining atoms with invalid valence. Proceeding anyway."
            end
            recompute_bonds = sanity_checks!(poss, types, graph, cell.mat, bondingmode)
            @ifwarn if recompute_bonds
                 @warn "Remaining bonds of suspicious lengths. Proceeding anyway."
            end
            attributions = attribute_residues(topology, assert_use_existing_residues)
        end
    end

    if isempty(attributions)
        crystalnothing = Crystal{Nothing}(cell, types, nothing, poss, graph)
        ifexport(crystalnothing, splitext(splitdir(path)[2])[1], exportto)
        return crystalnothing
    else
        crystalclusters = Crystal{Clusters}(cell, types, regroup_sbus(graph, attributions), poss, graph)
        ifexport(crystalclusters, splitext(splitdir(path)[2])[1], exportto)
        return crystalclusters
    end
end
