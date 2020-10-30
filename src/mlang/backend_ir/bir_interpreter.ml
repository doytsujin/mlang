(* Copyright (C) 2019 Inria, contributor: Denis Merigoux <denis.merigoux@inria.fr>

   This program is free software: you can redistribute it and/or modify it under the terms of the
   GNU General Public License as published by the Free Software Foundation, either version 3 of the
   License, or (at your option) any later version.

   This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without
   even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
   General Public License for more details.

   You should have received a copy of the GNU General Public License along with this program. If
   not, see <https://www.gnu.org/licenses/>. *)

open Mir

let repl_debug = ref false

let exit_on_rte = ref true

(* Careful : this behavior mimics the one imposed by the original Mlang compiler... *)
let truncatef x = snd (modf (x +. 0.000001))

(* Careful : rounding in M is done with this arbitrary behavior *)
let roundf x = snd (modf (x +. copysign 0.50005 x))

type var_literal = SimpleVar of literal | TableVar of int * literal array

let format_var_literal (fmt : Format.formatter) (var_lit : var_literal) : unit =
  match var_lit with
  | SimpleVar e -> Format.fprintf fmt "%a" Format_mir.format_literal e
  | TableVar (_, es) ->
      Format.fprintf fmt "[%a]"
        (Format.pp_print_list
           ~pp_sep:(fun fmt () -> Format.fprintf fmt "; ")
           (fun fmt e -> Format.fprintf fmt "%a" Format_mir.format_literal e))
        (Array.to_list es)

let format_var_literal_with_var fmt ((var, vl) : Variable.t * var_literal) =
  match vl with
  | SimpleVar value ->
      Format.fprintf fmt "%s (%s): %a" (Pos.unmark var.Variable.name)
        (Pos.unmark var.Variable.descr) Format_mir.format_literal value
  | TableVar (size, values) ->
      Format.fprintf fmt "%s (%s): Table (%d values)@\n" (Pos.unmark var.Variable.name)
        (Pos.unmark var.Variable.descr) size;
      List.iteri
        (fun idx value -> Format.fprintf fmt "| %d -> %a\n" idx Format_mir.format_literal value)
        (Array.to_list values)

type ctx = {
  ctx_local_vars : literal Pos.marked LocalVariableMap.t;
  ctx_vars : var_literal VariableMap.t;
  ctx_generic_index : int option;
}

let empty_ctx : ctx =
  {
    ctx_local_vars = LocalVariableMap.empty;
    ctx_vars = VariableMap.empty;
    ctx_generic_index = None;
  }

let int_of_bool (b : bool) = if b then 1 else 0

let is_zero (l : literal) : bool = match l with Float 0. -> true | _ -> false

let float_of_bool (b : bool) = if b then 1. else 0.

let bool_of_float (f : float) : bool = not (f = 0.)

let repl_debugguer (ctx : ctx) (p : Mir.program) : unit =
  Cli.warning_print
    "Starting interactive debugger. Please query the interpreter state for the values of \
     variables. Exit with \"quit\".@\n";
  let exit = ref false in
  while not !exit do
    Format.printf "> @?";
    let query = read_line () in
    if query = "quit" then exit := true
    else if query = "explain" then begin
      Format.printf ">> @?";
      let query = read_line () in
      try
        let vars = Pos.VarNameToID.find query p.Mir.program_idmap in
        let vars =
          List.sort
            (fun var1 var2 ->
              compare_execution_number var1.Variable.execution_number var2.Variable.execution_number)
            vars
        in
        List.iter
          (fun var ->
            Format.printf "[%a %a] -> %a@\n" Format_mir.format_execution_number_short
              var.Variable.execution_number Pos.format_position var.Variable.execution_number.pos
              (fun fmt () ->
                try
                  Format_mir.format_variable_def fmt
                    (VariableMap.find var p.program_vars).Mir.var_definition
                with Not_found -> Format.fprintf fmt "unused definition")
              ())
          vars
      with Not_found -> Format.printf "Inexisting variable@\n"
    end
    else
      try
        let vars = Pos.VarNameToID.find query p.Mir.program_idmap in
        let vars =
          List.sort
            (fun var1 var2 ->
              compare_execution_number var1.Variable.execution_number var2.Variable.execution_number)
            vars
        in
        List.iter
          (fun var ->
            try
              let var_l = Mir.VariableMap.find var ctx.ctx_vars in
              Format.printf "[%a %a] -> %a@\n" Format_mir.format_execution_number_short
                var.Variable.execution_number Pos.format_position var.Variable.execution_number.pos
                format_var_literal_with_var (var, var_l)
            with Not_found ->
              Format.printf "[%a %a] -> not computed@\n" Format_mir.format_execution_number_short
                var.Variable.execution_number Pos.format_position var.Variable.execution_number.pos)
          vars
      with Not_found -> Format.printf "Inexisting variable@\n"
  done

type run_error =
  | ErrorValue of string
  | FloatIndex of string
  | IndexOutOfBounds of string
  | IncorrectOutputVariable of string
  | UnknownInputVariable of string
  | ConditionViolated of Error.t list * expression Pos.marked * (Variable.t * var_literal) list

exception RuntimeError of run_error * ctx

let raise_runtime_as_structured (e : run_error) (ctx : ctx) (p : program) =
  match e with
  | ErrorValue s -> Errors.raise_error (Format.asprintf "Error value at runtime: %s" s)
  | FloatIndex s -> Errors.raise_error (Format.asprintf "Index is not an integer: %s" s)
  | IndexOutOfBounds s -> Errors.raise_error (Format.asprintf "Index out of bounds: %s" s)
  | UnknownInputVariable s -> Errors.raise_error (Format.asprintf "Unknown input variable: %s" s)
  | IncorrectOutputVariable s ->
      Errors.raise_error (Format.asprintf "Incorrect output variable: %s" s)
  | ConditionViolated (errors, condition, bindings) ->
      Errors.raise_spanned_error_with_continuation
        (Format.asprintf
           "Verification condition failed! Errors thrown:\n\
           \  * %a\n\
            Violated condition:\n\
           \  * %a\n\
            Values of the relevant variables at this point:\n\
            %a"
           (Format_mast.pp_print_list_endline (fun fmt err ->
                Format.fprintf fmt "Error %s [%s]" (Pos.unmark err.Error.name)
                  (Pos.unmark err.Error.descr)))
           errors Format_mir.format_expression (Pos.unmark condition)
           (Format_mast.pp_print_list_endline (fun fmt v ->
                Format.fprintf fmt "  * %a" format_var_literal_with_var v))
           bindings)
        (Pos.get_position condition)
        (fun _ -> repl_debugguer ctx p)

let evaluate_array_index (ctx : ctx) (index : literal) (size : int) (values : literal array)
    (pos : Pos.t) : literal =
  let idx =
    match index with
    | Undefined -> assert false (* should not happen *)
    | Float f ->
        if
          let fraction, _ = modf f in
          fraction = 0.
        then int_of_float f
        else raise (RuntimeError (FloatIndex (Format.asprintf "%a" Pos.format_position pos), ctx))
  in
  if idx >= size then Undefined else if idx < 0 then Float 0. else values.(idx)

let eval_debug = ref false

let rec evaluate_expr (ctx : ctx) (p : Mir.program) (e : expression Pos.marked) : literal =
  try
    match Pos.unmark e with
    | Comparison (op, e1, e2) ->
        let new_e1 = evaluate_expr ctx p e1 in
        let new_e2 = evaluate_expr ctx p e2 in
        let l =
          match (Pos.unmark op, new_e1, new_e2) with
          | Mast.Gt, Float i1, Float i2 -> Float (float_of_bool (i1 > i2))
          | Mast.Gt, _, Undefined | Mast.Gt, Undefined, _ -> Undefined
          | Mast.Gte, Float i1, Float i2 -> Float (float_of_bool (i1 >= i2))
          | Mast.Gte, _, Undefined | Mast.Gte, Undefined, _ -> Undefined
          | Mast.Lt, Float i1, Float i2 -> Float (float_of_bool (i1 < i2))
          | Mast.Lt, _, Undefined | Mast.Lt, Undefined, _ -> Undefined
          | Mast.Lte, Float i1, Float i2 -> Float (float_of_bool (i1 <= i2))
          | Mast.Lte, _, Undefined | Mast.Lte, Undefined, _ -> Undefined
          | Mast.Eq, Float i1, Float i2 -> Float (float_of_bool (i1 = i2))
          | Mast.Eq, _, Undefined | Mast.Eq, Undefined, _ -> Undefined
          | Mast.Neq, Float i1, Float i2 -> Float (float_of_bool (i1 <> i2))
          | Mast.Neq, _, Undefined | Mast.Neq, Undefined, _ -> Undefined
        in
        evaluate_expr ctx p (Pos.same_pos_as (Literal l) e)
    | Binop (op, e1, e2) ->
        let new_e1 = evaluate_expr ctx p e1 in
        let new_e2 = evaluate_expr ctx p e2 in
        let l =
          match (Pos.unmark op, new_e1, new_e2) with
          | Mast.Add, Float i1, Float i2 -> Float (i1 +. i2)
          | Mast.Add, Float i1, Undefined -> Float (i1 +. 0.)
          | Mast.Add, Undefined, Float i2 -> Float (0. +. i2)
          | Mast.Add, Undefined, Undefined -> Undefined
          | Mast.Sub, Float i1, Float i2 -> Float (i1 -. i2)
          | Mast.Sub, Float i1, Undefined -> Float (i1 -. 0.)
          | Mast.Sub, Undefined, Float i2 -> Float (0. -. i2)
          | Mast.Sub, Undefined, Undefined -> Undefined
          | Mast.Mul, _, Undefined | Mast.Mul, Undefined, _ -> Undefined
          | Mast.Mul, Float i1, Float i2 -> Float (i1 *. i2)
          | Mast.Div, Undefined, _ | Mast.Div, _, Undefined -> Undefined (* yes... *)
          | Mast.Div, _, l2 when is_zero l2 -> Float 0.
          | Mast.Div, Float i1, Float i2 -> Float (i1 /. i2)
          | Mast.And, Undefined, _
          | Mast.And, _, Undefined
          | Mast.Or, Undefined, _
          | Mast.Or, _, Undefined ->
              Undefined
          | Mast.And, Float i1, Float i2 ->
              Float (float_of_bool (bool_of_float i1 && bool_of_float i2))
          | Mast.Or, Float i1, Float i2 ->
              Float (float_of_bool (bool_of_float i1 || bool_of_float i2))
        in
        evaluate_expr ctx p (Pos.same_pos_as (Literal l) e)
    | Unop (op, e1) ->
        let new_e1 = evaluate_expr ctx p e1 in
        let l =
          match (op, new_e1) with
          | Mast.Not, Float b1 -> Float (float_of_bool (not (bool_of_float b1)))
          | Mast.Minus, Float f1 -> Float (-.f1)
          | Mast.Not, Undefined -> Undefined
          | Mast.Minus, Undefined -> Float 0.
        in
        evaluate_expr ctx p (Pos.same_pos_as (Literal l) e)
    | Conditional (e1, e2, e3) -> (
        let new_e1 = evaluate_expr ctx p e1 in
        match new_e1 with
        | Float 0. -> evaluate_expr ctx p e3
        | Float _ -> evaluate_expr ctx p e2 (* the float is not zero *)
        | Undefined -> Undefined )
    | Literal l -> l
    | Index (var, e1) -> (
        let new_e1 = evaluate_expr ctx p e1 in
        if new_e1 = Undefined then Undefined
        else
          match VariableMap.find (Pos.unmark var) ctx.ctx_vars with
          | SimpleVar _ -> assert false (* should not happen *)
          | TableVar (size, values) ->
              evaluate_array_index ctx new_e1 size values (Pos.get_position e1) )
    | LocalVar lvar -> (
        try Pos.unmark (LocalVariableMap.find lvar ctx.ctx_local_vars)
        with Not_found -> assert false (* should not happen*) )
    | Var var ->
        let r =
          try
            match VariableMap.find var ctx.ctx_vars with
            | SimpleVar l -> l
            | TableVar _ -> assert false
            (* should not happen *)
          with Not_found ->
            Errors.raise_spanned_error
              ("Var not found (should not happen): " ^ Pos.unmark var.Variable.name)
              (Pos.get_position e)
        in
        r
    | GenericTableIndex -> (
        match ctx.ctx_generic_index with
        | None -> assert false (* should not happen *)
        | Some i -> Float (float_of_int i) )
    | Error ->
        raise
          (RuntimeError
             (ErrorValue (Format.asprintf "%a" Pos.format_position (Pos.get_position e)), ctx))
    | LocalLet (lvar, e1, e2) ->
        let new_e1 = evaluate_expr ctx p e1 in
        let new_e2 =
          evaluate_expr
            {
              ctx with
              ctx_local_vars =
                LocalVariableMap.add lvar (Pos.same_pos_as new_e1 e1) ctx.ctx_local_vars;
            }
            p e2
        in
        new_e2
    | FunctionCall (ArrFunc, [ arg ]) ->
        let new_arg = evaluate_expr ctx p arg in
        let l =
          match new_arg with Float x -> Float (roundf x) | Undefined -> Undefined
          (*nope:Float 0.*)
        in
        evaluate_expr ctx p (Pos.same_pos_as (Literal l) e)
    | FunctionCall (InfFunc, [ arg ]) ->
        let new_arg = evaluate_expr ctx p arg in
        let l =
          match new_arg with Float x -> Float (truncatef x) | Undefined -> Undefined
          (*Float 0.*)
        in
        evaluate_expr ctx p (Pos.same_pos_as (Literal l) e)
    | FunctionCall (PresentFunc, [ arg ]) ->
        let l =
          match evaluate_expr ctx p arg with Undefined -> false_literal | _ -> true_literal
        in
        evaluate_expr ctx p (Pos.same_pos_as (Literal l) e)
    | FunctionCall (MinFunc, [ arg1; arg2 ]) ->
        let mini =
          match (evaluate_expr ctx p arg1, evaluate_expr ctx p arg2) with
          | Undefined, Float f | Float f, Undefined -> Float (min 0. f)
          | Undefined, Undefined -> Float 0.
          | Float fl, Float fr -> Float (min fl fr)
        in
        evaluate_expr ctx p (Pos.same_pos_as (Literal mini) e)
    | FunctionCall (MaxFunc, [ arg1; arg2 ]) ->
        let maxi =
          match (evaluate_expr ctx p arg1, evaluate_expr ctx p arg2) with
          | Undefined, Undefined -> Float 0.
          | Undefined, Float f | Float f, Undefined -> Float (max 0. f)
          | Float fl, Float fr -> Float (max fl fr)
        in
        evaluate_expr ctx p (Pos.same_pos_as (Literal maxi) e)
    | FunctionCall (Multimax, [ arg1; arg2 ]) ->
        let up =
          match evaluate_expr ctx p arg1 with
          | Float f when float_of_int (int_of_float f) = f -> int_of_float f
          | e ->
              raise
                (RuntimeError
                   ( ErrorValue
                       (Format.asprintf "evaluation of %a should be an integer, not %a"
                          Format_mir.format_expression (Pos.unmark arg1) Format_mir.format_literal
                          e),
                     ctx ))
        in
        let var_arg2 =
          match Pos.unmark arg2 with Var v -> v | _ -> assert false
          (* todo: rte *)
        in
        let cast_to_int e =
          match e with
          | Float f when float_of_int (int_of_float f) = f -> Some (int_of_float f)
          | Undefined -> Some 0
          | _ -> assert false
        in
        let pos = Pos.get_position arg2 in
        let access_index i =
          cast_to_int
          @@ evaluate_expr ctx p
               (Index ((var_arg2, pos), (Literal (Float (float_of_int i)), pos)), pos)
        in

        let maxi = ref (access_index 0) in
        for i = 0 to up do
          maxi := max !maxi (access_index i)
        done;
        let l = match !maxi with None -> Undefined | Some f -> Float (float_of_int f) in
        (* let l = match !maxi with None -> Undefined | Some v -> Float (float_of_int v) in *)
        evaluate_expr ctx p (Pos.same_pos_as (Literal l) e)
    | FunctionCall (func, _) ->
        raise
          (RuntimeError
             ( ErrorValue
                 (Format.asprintf "the function %a %a has not been expanded" Format_mir.format_func
                    func Pos.format_position (Pos.get_position e)),
               ctx ))
  with RuntimeError (e, ctx) ->
    if !exit_on_rte then raise_runtime_as_structured e ctx p else raise (RuntimeError (e, ctx))

let report_violatedcondition (cond : condition_data) (ctx : ctx) : 'a =
  raise
    (RuntimeError
       ( ConditionViolated
           ( cond.cond_errors,
             cond.cond_expr,
             List.rev
             @@ List.fold_left
                  (fun acc var -> (var, VariableMap.find var ctx.ctx_vars) :: acc)
                  []
                  (List.map
                     (fun (x, _) -> x)
                     (Mir.VariableMap.bindings
                        (Mir_dependency_graph.get_used_variables cond.cond_expr))) ),
         ctx ))

(* During evaluation, variables that have an I/O property set to InputVariable have a value that is
   read directly from the input map. However, one can pass inside the input map a value for a
   variable whose I/O type was not properly set to InputVariable. This function is precisely for
   these cases, it set the I/O flag properly for execution. Not that such a change to the program
   does not require to recompute the dependency graph and the execution order. *)
let replace_undefined_with_input_variables (p : program) (input_values : literal VariableMap.t) :
    program =
  VariableMap.fold
    (fun var _ p ->
      try
        let old_var_data = VariableMap.find var p.program_vars in
        {
          p with
          program_vars =
            VariableMap.add var
              { old_var_data with var_definition = InputVar; var_io = Input }
              p.program_vars;
        }
      with Not_found ->
        raise
          (RuntimeError
             ( UnknownInputVariable
                 (Format.asprintf "%s (%s)"
                    (Pos.unmark var.Mir.Variable.name)
                    (Pos.unmark var.Mir.Variable.descr)),
               empty_ctx )))
    input_values p

type code_location_segment = InsideBlock of int | ConditionalBranch of bool

let format_code_location_segment (fmt : Format.formatter) (s : code_location_segment) =
  match s with
  | InsideBlock i -> Format.fprintf fmt "#%d" i
  | ConditionalBranch b -> Format.fprintf fmt "?%b" b

type code_location = code_location_segment list

let format_code_location (fmt : Format.formatter) (l : code_location) =
  Format.pp_print_list
    ~pp_sep:(fun fmt _ -> Format.fprintf fmt "->")
    format_code_location_segment fmt l

let assign_hook : (Mir.Variable.t -> var_literal -> code_location -> unit) ref =
  ref (fun _var _lit _code_loc -> ())

let evaluate_variable (p : Bir.program) (ctx : ctx) (vdef : variable_def) : var_literal =
  match vdef with
  | Mir.SimpleVar e -> SimpleVar (evaluate_expr ctx p.mir_program e)
  | Mir.TableVar (size, es) ->
      TableVar
        ( size,
          Array.init size (fun idx ->
              match es with
              | IndexGeneric e ->
                  evaluate_expr { ctx with ctx_generic_index = Some idx } p.mir_program e
              | IndexTable es ->
                  let e = IndexMap.find idx es in
                  evaluate_expr ctx p.mir_program e) )
  | Mir.InputVar -> assert false

let rec evaluate_stmt (p : Bir.program) (ctx : ctx) (stmt : Bir.stmt) (loc : code_location) =
  match Pos.unmark stmt with
  | Bir.SAssign (var, vdata) ->
      let res = evaluate_variable p ctx vdata.var_definition in
      !assign_hook var res loc;
      { ctx with ctx_vars = VariableMap.add var res ctx.ctx_vars }
  | Bir.SConditional (b, t, f) -> (
      match evaluate_variable p ctx (SimpleVar (b, Pos.no_pos)) with
      | SimpleVar (Float 0.) -> evaluate_stmts p ctx f (ConditionalBranch false :: loc) 0
      | SimpleVar (Float _) -> evaluate_stmts p ctx t (ConditionalBranch true :: loc) 0
      | SimpleVar Undefined -> ctx
      | _ -> assert false )
  | Bir.SVerif data -> (
      match evaluate_expr ctx p.mir_program data.cond_expr with
      | Float f when f = 1. -> report_violatedcondition data ctx
      | _ -> ctx )

and evaluate_stmts (p : Bir.program) (ctx : ctx) (stmts : Bir.stmt list) (loc : code_location)
    (start_value : int) : ctx =
  let ctx, _ =
    List.fold_left
      (fun (ctx, i) stmt -> (evaluate_stmt p ctx stmt (InsideBlock i :: loc), i + 1))
      (ctx, start_value) stmts
  in
  ctx

let update_ctx_with_inputs (ctx : ctx) (inputs : literal VariableMap.t) : ctx =
  {
    ctx with
    ctx_vars =
      VariableMap.fold
        (fun var value ctx_vars -> VariableMap.add var (SimpleVar value) ctx_vars)
        inputs ctx.ctx_vars;
  }

let evaluate_program (p : Bir.program) (ctx : ctx) (code_loc_start_value : int) : ctx =
  try evaluate_stmts p ctx p.statements [] code_loc_start_value
  with RuntimeError (e, ctx) ->
    if !exit_on_rte then raise_runtime_as_structured e ctx p.mir_program
    else raise (RuntimeError (e, ctx))