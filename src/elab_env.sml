(* Copyright (c) 2008, Adam Chlipala
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * - The names of contributors may not be used to endorse or promote products
 *   derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *)

structure ElabEnv :> ELAB_ENV = struct

open Elab

structure U = ElabUtil

structure IM = IntBinaryMap
structure SM = BinaryMapFn(struct
                           type ord_key = string
                           val compare = String.compare
                           end)

exception UnboundRel of int
exception UnboundNamed of int


(* AST utility functions *)

exception SynUnif

val liftConInCon =
    U.Con.mapB {kind = fn k => k,
                con = fn bound => fn c =>
                                     case c of
                                         CRel xn =>
                                         if xn < bound then
                                             c
                                         else
                                             CRel (xn + 1)
                                       (*| CUnif _ => raise SynUnif*)
                                       | _ => c,
                bind = fn (bound, U.Con.Rel _) => bound + 1
                        | (bound, _) => bound}

val lift = liftConInCon 0

val liftExpInExp =
    U.Exp.mapB {kind = fn k => k,
                con = fn _ => fn c => c,
                exp = fn bound => fn e =>
                                     case e of
                                         ERel xn =>
                                         if xn < bound then
                                             e
                                         else
                                             ERel (xn + 1)
                                       | _ => e,
                bind = fn (bound, U.Exp.RelE _) => bound + 1
                        | (bound, _) => bound}


val liftExp = liftExpInExp 0

(* Back to environments *)

datatype 'a var' =
         Rel' of int * 'a
       | Named' of int * 'a

datatype 'a var =
         NotBound
       | Rel of int * 'a
       | Named of int * 'a

type datatyp = string list * (string * con option) IM.map

datatype class_name =
         ClNamed of int
       | ClProj of int * string list * string

fun cn2s cn =
    case cn of
        ClNamed n => "Named(" ^ Int.toString n ^ ")"
      | ClProj (m, ms, x) => "Proj(" ^ Int.toString m ^ "," ^ String.concatWith "," ms ^ "," ^ x ^ ")"

structure CK = struct
type ord_key = class_name
open Order
fun compare x =
    case x of
        (ClNamed n1, ClNamed n2) => Int.compare (n1, n2)
      | (ClNamed _, _) => LESS
      | (_, ClNamed _) => GREATER

      | (ClProj (m1, ms1, x1), ClProj (m2, ms2, x2)) =>
        join (Int.compare (m1, m2),
              fn () => join (joinL String.compare (ms1, ms2),
                             fn () => String.compare (x1, x2)))
end

structure CM = BinaryMapFn(CK)

datatype class_key =
         CkNamed of int
       | CkRel of int
       | CkProj of int * string list * string

fun ck2s ck =
    case ck of
        CkNamed n => "Named(" ^ Int.toString n ^ ")"
      | CkRel n => "Rel(" ^ Int.toString n ^ ")"
      | CkProj (m, ms, x) => "Proj(" ^ Int.toString m ^ "," ^ String.concatWith "," ms ^ "," ^ x ^ ")"

fun cp2s (cn, ck) = "(" ^ cn2s cn ^ "," ^ ck2s ck ^ ")"

structure KK = struct
type ord_key = class_key
open Order
fun compare x =
    case x of
        (CkNamed n1, CkNamed n2) => Int.compare (n1, n2)
      | (CkNamed _, _) => LESS
      | (_, CkNamed _) => GREATER

      | (CkRel n1, CkRel n2) => Int.compare (n1, n2)
      | (CkRel _, _) => LESS
      | (_, CkRel _) => GREATER

      | (CkProj (m1, ms1, x1), CkProj (m2, ms2, x2)) =>
        join (Int.compare (m1, m2),
              fn () => join (joinL String.compare (ms1, ms2),
                             fn () => String.compare (x1, x2)))
end

structure KM = BinaryMapFn(KK)

type class = {
     ground : exp KM.map
}

val empty_class = {
    ground = KM.empty
}

fun printClasses cs = CM.appi (fn (cn, {ground = km}) =>
                                  (print (cn2s cn ^ ":");
                                   KM.appi (fn (ck, _) => print (" " ^ ck2s ck)) km;
                                   print "\n")) cs

type env = {
     renameC : kind var' SM.map,
     relC : (string * kind) list,
     namedC : (string * kind * con option) IM.map,

     datatypes : datatyp IM.map,
     constructors : (datatype_kind * int * string list * con option * int) SM.map,

     classes : class CM.map,

     renameE : con var' SM.map,
     relE : (string * con) list,
     namedE : (string * con) IM.map,

     renameSgn : (int * sgn) SM.map,
     sgn : (string * sgn) IM.map,

     renameStr : (int * sgn) SM.map,
     str : (string * sgn) IM.map
}

val namedCounter = ref 0

fun newNamed () =
    let
        val r = !namedCounter
    in
        namedCounter := r + 1;
        r
    end

val empty = {
    renameC = SM.empty,
    relC = [],
    namedC = IM.empty,

    datatypes = IM.empty,
    constructors = SM.empty,

    classes = CM.empty,

    renameE = SM.empty,
    relE = [],
    namedE = IM.empty,

    renameSgn = SM.empty,
    sgn = IM.empty,

    renameStr = SM.empty,
    str = IM.empty
}

fun liftClassKey ck =
    case ck of
        CkNamed _ => ck
      | CkRel n => CkRel (n + 1)
      | CkProj _ => ck

fun pushCRel (env : env) x k =
    let
        val renameC = SM.map (fn Rel' (n, k) => Rel' (n+1, k)
                               | x => x) (#renameC env)
    in
        {renameC = SM.insert (renameC, x, Rel' (0, k)),
         relC = (x, k) :: #relC env,
         namedC = IM.map (fn (x, k, co) => (x, k, Option.map lift co)) (#namedC env),

         datatypes = #datatypes env,
         constructors = #constructors env,

         classes = CM.map (fn class => {
                              ground = KM.foldli (fn (ck, e, km) =>
                                                     KM.insert (km, liftClassKey ck, e))
                                                 KM.empty (#ground class)
                          })
                          (#classes env),

         renameE = #renameE env,
         relE = map (fn (x, c) => (x, lift c)) (#relE env),
         namedE = IM.map (fn (x, c) => (x, lift c)) (#namedE env),

         renameSgn = #renameSgn env,
         sgn = #sgn env,

         renameStr = #renameStr env,
         str = #str env
        }
    end

fun lookupCRel (env : env) n =
    (List.nth (#relC env, n))
    handle Subscript => raise UnboundRel n

fun pushCNamedAs (env : env) x n k co =
    {renameC = SM.insert (#renameC env, x, Named' (n, k)),
     relC = #relC env,
     namedC = IM.insert (#namedC env, n, (x, k, co)),

     datatypes = #datatypes env,
     constructors = #constructors env,

     classes = #classes env,

     renameE = #renameE env,
     relE = #relE env,
     namedE = #namedE env,

     renameSgn = #renameSgn env,
     sgn = #sgn env,
     
     renameStr = #renameStr env,
     str = #str env}

fun pushCNamed env x k co =
    let
        val n = !namedCounter
    in
        namedCounter := n + 1;
        (pushCNamedAs env x n k co, n)
    end

fun lookupCNamed (env : env) n =
    case IM.find (#namedC env, n) of
        NONE => raise UnboundNamed n
      | SOME x => x

fun lookupC (env : env) x =
    case SM.find (#renameC env, x) of
        NONE => NotBound
      | SOME (Rel' x) => Rel x
      | SOME (Named' x) => Named x

fun pushDatatype (env : env) n xs xncs =
    let
        val dk = U.classifyDatatype xncs
    in
        {renameC = #renameC env,
         relC = #relC env,
         namedC = #namedC env,

         datatypes = IM.insert (#datatypes env, n,
                                (xs, foldl (fn ((x, n, to), cons) =>
                                               IM.insert (cons, n, (x, to))) IM.empty xncs)),
         constructors = foldl (fn ((x, n', to), cmap) =>
                                  SM.insert (cmap, x, (dk, n', xs, to, n)))
                              (#constructors env) xncs,

         classes = #classes env,

         renameE = #renameE env,
         relE = #relE env,
         namedE = #namedE env,

         renameSgn = #renameSgn env,
         sgn = #sgn env,

         renameStr = #renameStr env,
         str = #str env}
    end

fun lookupDatatype (env : env) n =
    case IM.find (#datatypes env, n) of
        NONE => raise UnboundNamed n
      | SOME x => x

fun lookupDatatypeConstructor (_, dt) n =
    case IM.find (dt, n) of
        NONE => raise UnboundNamed n
      | SOME x => x

fun lookupConstructor (env : env) s = SM.find (#constructors env, s)

fun datatypeArgs (xs, _) = xs
fun constructors (_, dt) = IM.foldri (fn (n, (x, to), ls) => (x, n, to) :: ls) [] dt

fun pushClass (env : env) n =
    {renameC = #renameC env,
     relC = #relC env,
     namedC = #namedC env,

     datatypes = #datatypes env,
     constructors = #constructors env,

     classes = CM.insert (#classes env, ClNamed n, {ground = KM.empty}),

     renameE = #renameE env,
     relE = #relE env,
     namedE = #namedE env,

     renameSgn = #renameSgn env,
     sgn = #sgn env,

     renameStr = #renameStr env,
     str = #str env}    

fun class_name_in (c, _) =
    case c of
        CNamed n => SOME (ClNamed n)
      | CModProj x => SOME (ClProj x)
      | _ => NONE

fun class_key_in (c, _) =
    case c of
        CRel n => SOME (CkRel n)
      | CNamed n => SOME (CkNamed n)
      | CModProj x => SOME (CkProj x)
      | _ => NONE

fun class_pair_in (c, _) =
    case c of
        CApp (f, x) =>
        (case (class_name_in f, class_key_in x) of
             (SOME f, SOME x) => SOME (f, x)
           | _ => NONE)
      | _ => NONE

fun resolveClass (env : env) c =
    case class_pair_in c of
        SOME (f, x) =>
        (case CM.find (#classes env, f) of
             NONE => NONE
           | SOME class =>
             case KM.find (#ground class, x) of
                 NONE => NONE
               | SOME e => SOME e)
      | _ => NONE

fun pushERel (env : env) x t =
    let
        val renameE = SM.map (fn Rel' (n, t) => Rel' (n+1, t)
                               | x => x) (#renameE env)

        val classes = CM.map (fn class => {
                                 ground = KM.map liftExp (#ground class)
                             }) (#classes env)
        val classes = case class_pair_in t of
                          NONE => classes
                        | SOME (f, x) =>
                          let
                              val class = Option.getOpt (CM.find (classes, f), empty_class)
                              val class = {
                                  ground = KM.insert (#ground class, x, (ERel 0, #2 t))
                              }
                          in
                              CM.insert (classes, f, class)
                          end
    in
        {renameC = #renameC env,
         relC = #relC env,
         namedC = #namedC env,

         datatypes = #datatypes env,
         constructors = #constructors env,

         classes = classes,

         renameE = SM.insert (renameE, x, Rel' (0, t)),
         relE = (x, t) :: #relE env,
         namedE = #namedE env,

         renameSgn = #renameSgn env,
         sgn = #sgn env,

         renameStr = #renameStr env,
         str = #str env}
    end

fun lookupERel (env : env) n =
    (List.nth (#relE env, n))
    handle Subscript => raise UnboundRel n

fun pushENamedAs (env : env) x n t =
    let
        val classes = #classes env
        val classes = case class_pair_in t of
                          NONE => classes
                        | SOME (f, x) =>
                          let
                              val class = Option.getOpt (CM.find (classes, f), empty_class)
                              val class = {
                                  ground = KM.insert (#ground class, x, (ENamed n, #2 t))
                              }
                          in
                              CM.insert (classes, f, class)
                          end
    in
        {renameC = #renameC env,
         relC = #relC env,
         namedC = #namedC env,

         datatypes = #datatypes env,
         constructors = #constructors env,

         classes = classes,

         renameE = SM.insert (#renameE env, x, Named' (n, t)),
         relE = #relE env,
         namedE = IM.insert (#namedE env, n, (x, t)),

         renameSgn = #renameSgn env,
         sgn = #sgn env,
         
         renameStr = #renameStr env,
         str = #str env}
    end

fun pushENamed env x t =
    let
        val n = !namedCounter
    in
        namedCounter := n + 1;
        (pushENamedAs env x n t, n)
    end

fun lookupENamed (env : env) n =
    case IM.find (#namedE env, n) of
        NONE => raise UnboundNamed n
      | SOME x => x

fun lookupE (env : env) x =
    case SM.find (#renameE env, x) of
        NONE => NotBound
      | SOME (Rel' x) => Rel x
      | SOME (Named' x) => Named x

fun pushSgnNamedAs (env : env) x n sgis =
    {renameC = #renameC env,
     relC = #relC env,
     namedC = #namedC env,

     datatypes = #datatypes env,
     constructors = #constructors env,

     classes = #classes env,

     renameE = #renameE env,
     relE = #relE env,
     namedE = #namedE env,

     renameSgn = SM.insert (#renameSgn env, x, (n, sgis)),
     sgn = IM.insert (#sgn env, n, (x, sgis)),
     
     renameStr = #renameStr env,
     str = #str env}

fun pushSgnNamed env x sgis =
    let
        val n = !namedCounter
    in
        namedCounter := n + 1;
        (pushSgnNamedAs env x n sgis, n)
    end

fun lookupSgnNamed (env : env) n =
    case IM.find (#sgn env, n) of
        NONE => raise UnboundNamed n
      | SOME x => x

fun lookupSgn (env : env) x = SM.find (#renameSgn env, x)

fun lookupStrNamed (env : env) n =
    case IM.find (#str env, n) of
        NONE => raise UnboundNamed n
      | SOME x => x

fun lookupStr (env : env) x = SM.find (#renameStr env, x)


fun sgiSeek (sgi, (sgns, strs, cons)) =
    case sgi of
        SgiConAbs (x, n, _) => (sgns, strs, IM.insert (cons, n, x))
      | SgiCon (x, n, _, _) => (sgns, strs, IM.insert (cons, n, x))
      | SgiDatatype (x, n, _, _) => (sgns, strs, IM.insert (cons, n, x))
      | SgiDatatypeImp (x, n, _, _, _, _, _) => (sgns, strs, IM.insert (cons, n, x))
      | SgiVal _ => (sgns, strs, cons)
      | SgiSgn (x, n, _) => (IM.insert (sgns, n, x), strs, cons)
      | SgiStr (x, n, _) => (sgns, IM.insert (strs, n, x), cons)
      | SgiConstraint _ => (sgns, strs, cons)
      | SgiTable _ => (sgns, strs, cons)
      | SgiClassAbs (x, n) => (sgns, strs, IM.insert (cons, n, x))
      | SgiClass (x, n, _) => (sgns, strs, IM.insert (cons, n, x))

fun sgnSeek f sgis =
    let
        fun seek (sgis, sgns, strs, cons) =
            case sgis of
                [] => NONE
              | (sgi, _) :: sgis =>
                case f sgi of
                    SOME v =>
                    let
                        val cons =
                            case sgi of
                                SgiDatatype (x, n, _, _) => IM.insert (cons, n, x)
                              | SgiDatatypeImp (x, n, _, _, _, _, _) => IM.insert (cons, n, x)
                              | _ => cons
                    in
                        SOME (v, (sgns, strs, cons))
                    end
                  | NONE =>
                    let
                        val (sgns, strs, cons) = sgiSeek (sgi, (sgns, strs, cons))
                    in
                        seek (sgis, sgns, strs, cons)
                    end
    in
        seek (sgis, IM.empty, IM.empty, IM.empty)
    end

fun id x = x

fun unravelStr (str, _) =
    case str of
        StrVar x => (x, [])
      | StrProj (str, m) =>
        let
            val (x, ms) = unravelStr str
        in
            (x, ms @ [m])
        end
      | _ => raise Fail "unravelStr"

fun sgnS_con (str, (sgns, strs, cons)) c =
    case c of
        CModProj (m1, ms, x) =>
        (case IM.find (strs, m1) of
             NONE => c
           | SOME m1x =>
             let
                 val (m1, ms') = unravelStr str
             in
                 CModProj (m1, ms' @ m1x :: ms, x)
             end)
      | CNamed n =>
        (case IM.find (cons, n) of
             NONE => c
           | SOME nx =>
             let
                 val (m1, ms) = unravelStr str
             in
                 CModProj (m1, ms, nx)
             end)
      | _ => c

fun sgnS_con' (m1, ms', (sgns, strs, cons)) c =
    case c of
        CModProj (m1, ms, x) =>
        (case IM.find (strs, m1) of
             NONE => c
           | SOME m1x => CModProj (m1, ms' @ m1x :: ms, x))
      | CNamed n =>
        (case IM.find (cons, n) of
             NONE => c
           | SOME nx => CModProj (m1, ms', nx))
      | _ => c

fun sgnS_sgn (str, (sgns, strs, cons)) sgn =
    case sgn of
        SgnProj (m1, ms, x) =>
        (case IM.find (strs, m1) of
             NONE => sgn
           | SOME m1x =>
             let
                 val (m1, ms') = unravelStr str
             in
                 SgnProj (m1, ms' @ m1x :: ms, x)
             end)
      | SgnVar n =>
        (case IM.find (sgns, n) of
             NONE => sgn
           | SOME nx =>
             let
                 val (m1, ms) = unravelStr str
             in
                 SgnProj (m1, ms, nx)
             end)
      | _ => sgn

fun sgnSubSgn x =
    ElabUtil.Sgn.map {kind = id,
                      con = sgnS_con x,
                      sgn_item = id,
                      sgn = sgnS_sgn x}



and projectSgn env {sgn, str, field} =
    case #1 (hnormSgn env sgn) of
        SgnConst sgis =>
        (case sgnSeek (fn SgiSgn (x, _, sgn) => if x = field then SOME sgn else NONE | _ => NONE) sgis of
             NONE => NONE
           | SOME (sgn, subs) => SOME (sgnSubSgn (str, subs) sgn))
      | SgnError => SOME (SgnError, ErrorMsg.dummySpan)
      | _ => NONE

and hnormSgn env (all as (sgn, loc)) =
    case sgn of
        SgnError => all
      | SgnVar n => hnormSgn env (#2 (lookupSgnNamed env n))
      | SgnConst _ => all
      | SgnFun _ => all
      | SgnProj (m, ms, x) =>
        let
            val (_, sgn) = lookupStrNamed env m
        in
            case projectSgn env {str = foldl (fn (m, str) => (StrProj (str, m), loc)) (StrVar m, loc) ms,
                                 sgn = sgn,
                                 field = x} of
                NONE => raise Fail "ElabEnv.hnormSgn: projectSgn failed"
              | SOME sgn => sgn
        end
      | SgnWhere (sgn, x, c) =>
        case #1 (hnormSgn env sgn) of
            SgnError => (SgnError, loc)
          | SgnConst sgis =>
            let
                fun traverse (pre, post) =
                    case post of
                        [] => raise Fail "ElabEnv.hnormSgn: Can't reduce 'where' [1]"
                      | (sgi as (SgiConAbs (x', n, k), loc)) :: rest =>
                        if x = x' then
                            List.revAppend (pre, (SgiCon (x', n, k, c), loc) :: rest)
                        else
                            traverse (sgi :: pre, rest)
                      | sgi :: rest => traverse (sgi :: pre, rest)

                val sgis = traverse ([], sgis)
            in
                (SgnConst sgis, loc)
            end
          | _ => raise Fail "ElabEnv.hnormSgn: Can't reduce 'where' [2]"

fun enrichClasses env classes (m1, ms) sgn =
    case #1 (hnormSgn env sgn) of
        SgnConst sgis =>
        let
            val (classes, _, _, _) =
                foldl (fn (sgi, (classes, newClasses, fmap, env)) =>
                          let
                              fun found (x, n) =
                                  (CM.insert (classes,
                                              ClProj (m1, ms, x),
                                              empty_class),
                                   IM.insert (newClasses, n, x),
                                   sgiSeek (#1 sgi, fmap),
                                   env)

                              fun default () = (classes, newClasses, sgiSeek (#1 sgi, fmap), env)
                          in
                              case #1 sgi of
                                  SgiStr (x, _, sgn) =>
                                  (enrichClasses env classes (m1, ms @ [x]) sgn,
                                   newClasses,
                                   sgiSeek (#1 sgi, fmap),
                                   env)
                                | SgiSgn (x, n, sgn) =>
                                  (classes,
                                   newClasses,
                                   fmap,
                                   pushSgnNamedAs env x n sgn)

                                | SgiClassAbs xn => found xn
                                | SgiClass (x, n, _) => found (x, n)
                                | SgiVal (x, n, (CApp ((CNamed f, _), a), _)) =>
                                  (case IM.find (newClasses, f) of
                                       NONE => default ()
                                     | SOME fx =>
                                       case class_key_in (sgnS_con' (m1, ms, fmap) (#1 a), #2 a) of
                                           NONE => default ()
                                         | SOME ck =>
                                           let
                                               val cn = ClProj (m1, ms, fx)
                                               val class = Option.getOpt (CM.find (classes, cn), empty_class)
                                               val class = {
                                                   ground = KM.insert (#ground class, ck,
                                                                       (EModProj (m1, ms, x), #2 sgn))
                                               }

                                           in
                                               (CM.insert (classes, cn, class),
                                                newClasses,
                                                fmap,
                                                env)
                                           end)
                                | SgiVal _ => default ()
                                | _ => default ()
                          end)
                      (classes, IM.empty, (IM.empty, IM.empty, IM.empty), env) sgis
        in
            classes
        end
      | _ => classes

fun pushStrNamedAs (env : env) x n sgn =
    {renameC = #renameC env,
     relC = #relC env,
     namedC = #namedC env,

     datatypes = #datatypes env,
     constructors = #constructors env,

     classes = enrichClasses env (#classes env) (n, []) sgn,

     renameE = #renameE env,
     relE = #relE env,
     namedE = #namedE env,

     renameSgn = #renameSgn env,
     sgn = #sgn env,

     renameStr = SM.insert (#renameStr env, x, (n, sgn)),
     str = IM.insert (#str env, n, (x, sgn))}

fun pushStrNamed env x sgn =
    let
        val n = !namedCounter
    in
        namedCounter := n + 1;
        (pushStrNamedAs env x n sgn, n)
    end

fun sgiBinds env (sgi, loc) =
    case sgi of
        SgiConAbs (x, n, k) => pushCNamedAs env x n k NONE
      | SgiCon (x, n, k, c) => pushCNamedAs env x n k (SOME c)
      | SgiDatatype (x, n, xs, xncs) =>
        let
            val env = pushCNamedAs env x n (KType, loc) NONE
        in
            foldl (fn ((x', n', to), env) =>
                      let
                          val t =
                              case to of
                                  NONE => (CNamed n, loc)
                                | SOME t => (TFun (t, (CNamed n, loc)), loc)

                          val k = (KType, loc)
                          val t = foldr (fn (x, t) => (TCFun (Explicit, x, k, t), loc)) t xs
                      in
                          pushENamedAs env x' n' t
                      end)
            env xncs
        end
      | SgiDatatypeImp (x, n, m1, ms, x', xs, xncs) =>
        let
            val env = pushCNamedAs env x n (KType, loc) (SOME (CModProj (m1, ms, x'), loc))
        in
            foldl (fn ((x', n', to), env) =>
                      let
                          val t =
                              case to of
                                  NONE => (CNamed n, loc)
                                | SOME t => (TFun (t, (CNamed n, loc)), loc)

                          val k = (KType, loc)
                          val t = foldr (fn (x, t) => (TCFun (Explicit, x, k, t), loc)) t xs
                      in
                          pushENamedAs env x' n' t
                      end)
            env xncs
        end
      | SgiVal (x, n, t) => pushENamedAs env x n t
      | SgiStr (x, n, sgn) => pushStrNamedAs env x n sgn
      | SgiSgn (x, n, sgn) => pushSgnNamedAs env x n sgn
      | SgiConstraint _ => env

      | SgiTable (tn, x, n, c) =>
        let
            val t = (CApp ((CModProj (tn, [], "table"), loc), c), loc)
        in
            pushENamedAs env x n t
        end

      | SgiClassAbs (x, n) => pushCNamedAs env x n (KArrow ((KType, loc), (KType, loc)), loc) NONE
      | SgiClass (x, n, c) => pushCNamedAs env x n (KArrow ((KType, loc), (KType, loc)), loc) (SOME c)
        

fun sgnSubCon x =
    ElabUtil.Con.map {kind = id,
                      con = sgnS_con x}

fun projectStr env {sgn, str, field} =
    case #1 (hnormSgn env sgn) of
        SgnConst sgis =>
        (case sgnSeek (fn SgiStr (x, _, sgn) => if x = field then SOME sgn else NONE | _ => NONE) sgis of
             NONE => NONE
           | SOME (sgn, subs) => SOME (sgnSubSgn (str, subs) sgn))
      | SgnError => SOME (SgnError, ErrorMsg.dummySpan)
      | _ => NONE

fun chaseMpath env (n, ms) =
    let
        val (_, sgn) = lookupStrNamed env n
    in
        foldl (fn (m, (str, sgn)) =>
                                   case projectStr env {sgn = sgn, str = str, field = m} of
                                       NONE => raise Fail "kindof: Unknown substructure"
                                     | SOME sgn => ((StrProj (str, m), #2 sgn), sgn))
                               ((StrVar n, #2 sgn), sgn) ms
    end

fun projectCon env {sgn, str, field} =
    case #1 (hnormSgn env sgn) of
        SgnConst sgis =>
        (case sgnSeek (fn SgiConAbs (x, _, k) => if x = field then SOME (k, NONE) else NONE
                        | SgiCon (x, _, k, c) => if x = field then SOME (k, SOME c) else NONE
                        | SgiDatatype (x, _, _, _) => if x = field then SOME ((KType, #2 sgn), NONE) else NONE
                        | SgiDatatypeImp (x, _, m1, ms, x', _, _) =>
                          if x = field then
                              SOME ((KType, #2 sgn), SOME (CModProj (m1, ms, x'), #2 sgn))
                          else
                              NONE
                        | SgiClassAbs (x, _) => if x = field then
                                                    SOME ((KArrow ((KType, #2 sgn), (KType, #2 sgn)), #2 sgn), NONE)
                                                else
                                                    NONE
                        | SgiClass (x, _, c) => if x = field then
                                                    SOME ((KArrow ((KType, #2 sgn), (KType, #2 sgn)), #2 sgn), SOME c)
                                                else
                                                    NONE
                        | _ => NONE) sgis of
             NONE => NONE
           | SOME ((k, co), subs) => SOME (k, Option.map (sgnSubCon (str, subs)) co))
      | SgnError => SOME ((KError, ErrorMsg.dummySpan), SOME (CError, ErrorMsg.dummySpan))
      | _ => NONE

fun projectDatatype env {sgn, str, field} =
    case #1 (hnormSgn env sgn) of
        SgnConst sgis =>
        (case sgnSeek (fn SgiDatatype (x, _, xs, xncs) => if x = field then SOME (xs, xncs) else NONE
                        | SgiDatatypeImp (x, _, _, _, _, xs, xncs) => if x = field then SOME (xs, xncs) else NONE
                        | _ => NONE) sgis of
             NONE => NONE
           | SOME ((xs, xncs), subs) => SOME (xs,
                                              map (fn (x, n, to) => (x, n, Option.map (sgnSubCon (str, subs)) to)) xncs))
      | _ => NONE

fun projectConstructor env {sgn, str, field} =
    case #1 (hnormSgn env sgn) of
        SgnConst sgis =>
        let
            fun consider (n, xs, xncs) =
                ListUtil.search (fn (x, n', to) =>
                                    if x <> field then
                                        NONE
                                    else
                                        SOME (U.classifyDatatype xncs, n', xs, to, (CNamed n, #2 str))) xncs
        in
            case sgnSeek (fn SgiDatatype (_, n, xs, xncs) => consider (n, xs, xncs)
                           | SgiDatatypeImp (_, n, _, _, _, xs, xncs) => consider (n, xs, xncs)
                           | _ => NONE) sgis of
                NONE => NONE
              | SOME ((dk, n, xs, to, t), subs) => SOME (dk, n, xs, Option.map (sgnSubCon (str, subs)) to,
                                                         sgnSubCon (str, subs) t)
        end
      | _ => NONE

fun projectVal env {sgn, str, field} =
    case #1 (hnormSgn env sgn) of
        SgnConst sgis =>
        let
            fun seek (n, xs, xncs) =
                ListUtil.search (fn (x, _, to) =>
                                    if x = field then
                                        SOME (let
                                                  val t =
                                                      case to of
                                                          NONE => (CNamed n, #2 sgn)
                                                        | SOME t => (TFun (t, (CNamed n, #2 sgn)), #2 sgn)
                                                  val k = (KType, #2 sgn)
                                              in
                                                  foldr (fn (x, t) => (TCFun (Explicit, x, k, t), #2 sgn))
                                                  t xs
                                              end)
                                    else
                                        NONE) xncs
        in
            case sgnSeek (fn SgiVal (x, _, c) => if x = field then SOME c else NONE
                           | SgiDatatype (_, n, xs, xncs) => seek (n, xs, xncs)
                           | SgiDatatypeImp (_, n, _, _, _, xs, xncs) => seek (n, xs, xncs)
                           | _ => NONE) sgis of
                NONE => NONE
              | SOME (c, subs) => SOME (sgnSubCon (str, subs) c)
        end
      | SgnError => SOME (CError, ErrorMsg.dummySpan)
      | _ => NONE

fun sgnSeekConstraints (str, sgis) =
    let
        fun seek (sgis, sgns, strs, cons, acc) =
            case sgis of
                [] => acc
              | (sgi, _) :: sgis =>
                case sgi of
                    SgiConstraint (c1, c2) =>
                    let
                        val sub = sgnSubCon (str, (sgns, strs, cons))
                    in
                        seek (sgis, sgns, strs, cons, (sub c1, sub c2) :: acc)
                    end
                  | SgiConAbs (x, n, _) => seek (sgis, sgns, strs, IM.insert (cons, n, x), acc)
                  | SgiCon (x, n, _, _) => seek (sgis, sgns, strs, IM.insert (cons, n, x), acc)
                  | SgiDatatype (x, n, _, _) => seek (sgis, sgns, strs, IM.insert (cons, n, x), acc)
                  | SgiDatatypeImp (x, n, _, _, _, _, _) => seek (sgis, sgns, strs, IM.insert (cons, n, x), acc)
                  | SgiVal _ => seek (sgis, sgns, strs, cons, acc)
                  | SgiSgn (x, n, _) => seek (sgis, IM.insert (sgns, n, x), strs, cons, acc)
                  | SgiStr (x, n, _) => seek (sgis, sgns, IM.insert (strs, n, x), cons, acc)
                  | SgiTable _ => seek (sgis, sgns, strs, cons, acc)
                  | SgiClassAbs (x, n) => seek (sgis, sgns, strs, IM.insert (cons, n, x), acc)
                  | SgiClass (x, n, _) => seek (sgis, sgns, strs, IM.insert (cons, n, x), acc)
    in
        seek (sgis, IM.empty, IM.empty, IM.empty, [])
    end

fun projectConstraints env {sgn, str} =
    case #1 (hnormSgn env sgn) of
        SgnConst sgis => SOME (sgnSeekConstraints (str, sgis))
      | SgnError => SOME []
      | _ => NONE

fun declBinds env (d, loc) =
    case d of
        DCon (x, n, k, c) => pushCNamedAs env x n k (SOME c)
      | DDatatype (x, n, xs, xncs) =>
        let
            val env = pushCNamedAs env x n (KType, loc) NONE
            val env = pushDatatype env n xs xncs
        in
            foldl (fn ((x', n', to), env) =>
                      let
                          val t =
                              case to of
                                  NONE => (CNamed n, loc)
                                | SOME t => (TFun (t, (CNamed n, loc)), loc)
                          val k = (KType, loc)
                          val t = foldr (fn (x, t) => (TCFun (Explicit, x, k, t), loc)) t xs
                      in
                          pushENamedAs env x' n' t
                      end)
                  env xncs
        end
      | DDatatypeImp (x, n, m, ms, x', xs, xncs) =>
        let
            val t = (CModProj (m, ms, x'), loc)
            val env = pushCNamedAs env x n (KType, loc) (SOME t)
            val env = pushDatatype env n xs xncs

            val t = (CNamed n, loc)
        in
            foldl (fn ((x', n', to), env) =>
                      let
                          val t =
                              case to of
                                  NONE => (CNamed n, loc)
                                | SOME t => (TFun (t, (CNamed n, loc)), loc)
                          val k = (KType, loc)
                          val t = foldr (fn (x, t) => (TCFun (Explicit, x, k, t), loc)) t xs
                      in
                          pushENamedAs env x' n' t
                      end)
                  env xncs
        end
      | DVal (x, n, t, _) => pushENamedAs env x n t
      | DValRec vis => foldl (fn ((x, n, t, _), env) => pushENamedAs env x n t) env vis
      | DSgn (x, n, sgn) => pushSgnNamedAs env x n sgn
      | DStr (x, n, sgn, _) => pushStrNamedAs env x n sgn
      | DFfiStr (x, n, sgn) => pushStrNamedAs env x n sgn
      | DConstraint _ => env
      | DExport _ => env
      | DTable (tn, x, n, c) =>
        let
            val t = (CApp ((CModProj (tn, [], "table"), loc), c), loc)
        in
            pushENamedAs env x n t
        end
      | DClass (x, n, c) =>
        let
            val k = (KArrow ((KType, loc), (KType, loc)), loc)
            val env = pushCNamedAs env x n k (SOME c)
        in
            pushClass env n
        end

end
