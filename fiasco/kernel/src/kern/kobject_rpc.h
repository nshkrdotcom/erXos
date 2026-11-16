// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: MIT
//
// Modified by erXos: this file is erXos's clean-room replacement of Fiasco's
// kobject_rpc.h, written without reading the original from the interface
// its MIT callers use and the message layout the l4sys client stubs send
// (fiasco/kernel/ORIGIN.md, the entry for this file, names the facts
// record it was written from).
//
// Decoding a kernel-object invocation.  The helpers check an invocation's
// protocol label, rights and size and resolve capability send items into
// typed kernel objects.  L4_RPC declares one method of an object's protocol:
// the generated Msg_<name>::call decodes the message for the declared
// argument list, calls the object's op_<name>() and builds the reply tag.
//
// The message layout of an L4_RPC method:
//  - word 0 of the input message registers is the opcode, which the
//    dispatching object reads itself to pick the Msg_<name>;
//  - by-value parameters are inputs, laid out from byte sizeof(Mword) of the
//    input registers in declaration order, each at the next offset aligned
//    to its type's alignment;
//  - pointer parameters T * are outputs, laid out the same way from byte 0
//    of the output registers; the handler writes through the pointer;
//  - Ko::Cap<T> parameters take no bytes: each resolves the next send item,
//    after the untyped words, in declaration order;
//  - reference parameters do not build.
// Every input is copied out of the user-writable UTCB, once, before any
// capability is resolved or the handler runs, so the handler never re-reads
// an input and its outputs, which may overlay the inputs, cannot change one.

#pragma once

#include <cxx/type_traits>
#include <cxx/dyn_cast>
#include "context.h"
#include "kobject_iface.h"
#include "l4_buf_iter.h"
#include "l4_types.h"
#include "space.h"

namespace Ko {

using Rights = L4_fpage::Rights;

inline L4_msg_tag
commit_result(Mword error, unsigned words = 0, unsigned items = 0)
{ return Kobject_iface::commit_result(error, words, items); }

inline L4_msg_tag
commit_error(Utcb const *utcb, L4_error const &e,
             L4_msg_tag const &tag = L4_msg_tag(0, 0, 0, 0))
{ return Kobject_iface::commit_error(utcb, e, tag); }

/**
 * Whether `rights` holds every capability right (CS, CW) of `need`; other
 * bits of `need` are not checked.  On failure, `*tag`, if given, becomes the
 * -EPerm reply.
 */
inline bool
check_rights(Rights rights, Rights need, L4_msg_tag *tag = nullptr)
{
  need &= Rights::CS() | Rights::CW();
  if ((rights & need) == need)
    return true;

  if (tag)
    *tag = commit_result(-L4_err::EPerm);
  return false;
}

/**
 * The entry check of an invocation: the label, then the rights, then at
 * least one untyped word.  On the first failure `*tag` becomes its error
 * reply (-EBadproto, -EPerm, -EMsgtooshort) and the result is false.
 */
inline bool
check_basics(L4_msg_tag *tag, Rights rights, long label, Rights need)
{
  if (tag->proto() != label) [[unlikely]]
    {
      *tag = commit_result(-L4_err::EBadproto);
      return false;
    }

  if (!check_rights(rights, need, tag)) [[unlikely]]
    return false;

  if (tag->words() < 1) [[unlikely]]
    {
      *tag = commit_result(-L4_err::EMsgtooshort);
      return false;
    }

  return true;
}

inline bool
check_basics(L4_msg_tag *tag, long label)
{ return check_basics(tag, Rights(0), label, Rights(0)); }

/// The number of message words that hold `bytes` bytes.
constexpr unsigned long
message_words(unsigned long bytes)
{ return (bytes + sizeof(Mword) - 1) / sizeof(Mword); }

/// Whether the untyped words cover `size` bytes and the message fits the UTCB.
inline bool
check_message_size(L4_msg_tag tag, unsigned long size)
{
  return tag.words() * sizeof(Mword) >= size
         && tag.words() + tag.items() <= Utcb::Max_words;
}

/**
 * Resolve the next send item of `items` as a capability to an `OBJ` in
 * `space`; `*rights` receives the capability's rights.  A missing or void
 * item, a missing object or one of another type sets `*tag` to -EInval; an
 * item that is not an object flexpage is an IPC overflow error.  Each
 * returns null.
 */
template<typename OBJ>
OBJ *
deref_next(L4_msg_tag *tag, Utcb const *utcb, L4_snd_item_iter &items,
           Space *space, Rights *rights)
{
  if (!items.next() || items.get()->b.is_void()) [[unlikely]]
    {
      *tag = commit_result(-L4_err::EInval);
      return nullptr;
    }

  L4_fpage const fpage(items.get()->d);
  if (!fpage.is_objpage()) [[unlikely]]
    {
      *tag = commit_error(utcb, L4_error::Overflow);
      return nullptr;
    }

  OBJ *obj = cxx::dyn_cast<OBJ *>(space->lookup_local(fpage.obj_index(), rights));
  if (!obj) [[unlikely]]
    *tag = commit_result(-L4_err::EInval);
  return obj;
}

/// The first send item as a capability to an `OBJ` in the caller's space.
template<typename OBJ>
__attribute__((nonnull)) OBJ *
deref(L4_msg_tag *tag, Utcb const *utcb, Rights *rights)
{
  if (tag->items() < 1) [[unlikely]]
    {
      *tag = commit_result(-L4_err::EInval);
      return nullptr;
    }

  L4_snd_item_iter items(utcb, tag->words());
  return deref_next<OBJ>(tag, utcb, items, ::current()->space(), rights);
}

/// A capability argument of an L4_RPC method, as resolved.
template<typename OBJ>
struct Cap
{
  typedef OBJ Obj_type;
  OBJ *obj;
  Rights rights;
};

namespace Rpc_detail {

enum class Kind { In, Out, Cap };

template<typename T> struct Is_cap : cxx::false_type {};
template<typename T> struct Is_cap<Cap<T>> : cxx::true_type {};

/// What an argument of type T is, and the size and alignment of its bytes.
template<typename T>
struct Arg
{
  static_assert(cxx::is_same<T, cxx::remove_reference_t<T>>::value,
                "L4_RPC: reference parameters are not supported");

  static constexpr Kind kind = Is_cap<T>::value ? Kind::Cap
                               : cxx::is_pointer<T>::value ? Kind::Out
                               : Kind::In;
};

template<typename T>
struct Data
{
  static constexpr unsigned long size = sizeof(T);
  static constexpr unsigned long align = alignof(T);
};

template<typename T>
struct Data<T *>
{
  static constexpr unsigned long size = sizeof(T);
  static constexpr unsigned long align = alignof(T);
};

template<typename T>
struct Data<Cap<T>>
{
  static constexpr unsigned long size = 0;
  static constexpr unsigned long align = 1;
};

constexpr unsigned long
align_up(unsigned long value, unsigned long align)
{ return (value + align - 1) & ~(align - 1); }

/// The byte layout of an argument list (one trailing sentinel entry each).
template<typename ...ARGS>
struct Layout
{
  static constexpr unsigned count = sizeof...(ARGS);
  static constexpr Kind kinds[] = { Arg<ARGS>::kind..., Kind::Cap };
  static constexpr unsigned long sizes[] = { Data<ARGS>::size..., 0 };
  static constexpr unsigned long aligns[] = { Data<ARGS>::align..., 1 };

  /// The offset of argument i in the layout of its kind k, which starts at
  /// byte `start`; for i == count, the end of that layout.
  static constexpr unsigned long
  offset(unsigned i, Kind k, unsigned long start)
  {
    unsigned long pos = start;
    for (unsigned j = 0; j < i; ++j)
      if (kinds[j] == k)
        pos = align_up(pos, aligns[j]) + sizes[j];
    return i < count ? align_up(pos, aligns[i]) : pos;
  }

  static constexpr unsigned long in_end = offset(count, Kind::In, sizeof(Mword));
  static constexpr unsigned long out_end = offset(count, Kind::Out, 0);
  static constexpr unsigned caps = ((Arg<ARGS>::kind == Kind::Cap) + ... + 0);
};

template<unsigned ...I> struct Indices {};
template<unsigned N, unsigned ...I>
struct Make_indices : Make_indices<N - 1, N - 1, I...> {};
template<unsigned ...I>
struct Make_indices<0, I...> { typedef Indices<I...> type; };

/// Storage for argument I: the resolved capability, or nothing.
template<unsigned I, typename T> struct Slot {};
template<unsigned I, typename T> struct Slot<I, Cap<T>> { Cap<T> value; };

template<typename INDICES, typename ...ARGS> struct Rpc;

template<unsigned ...I, typename ...ARGS>
struct Rpc<Indices<I...>, ARGS...>
{
  typedef Layout<ARGS...> L;
  struct Caps : Slot<I, ARGS>... {};

  // A tag's flag bits; a rebuilt reply keeps the handler's.
  static constexpr Mword Reply_flags = Mword{L4_msg_tag::Transfer_fpu}
                                       | Mword{L4_msg_tag::Schedule}
                                       | Mword{L4_msg_tag::Propagate}
                                       | Mword{L4_msg_tag::Error};

  template<unsigned J, typename T>
  static bool
  resolve(Caps &caps, L4_msg_tag *tag, Utcb const *in,
          L4_snd_item_iter &items, Space *space)
  {
    if constexpr (Arg<T>::kind == Kind::Cap)
      {
        T &cap = static_cast<Slot<J, T> &>(caps).value;
        cap.obj = deref_next<typename T::Obj_type>(tag, in, items, space,
                                                   &cap.rights);
        return cap.obj;
      }
    else
      return true;
  }

  template<unsigned J, typename T>
  static T
  argument(Caps &caps, unsigned char const *input, unsigned char *output)
  {
    if constexpr (Arg<T>::kind == Kind::Cap)
      return static_cast<Slot<J, T> &>(caps).value;
    else if constexpr (Arg<T>::kind == Kind::Out)
      return reinterpret_cast<T>(output + L::offset(J, Kind::Out, 0));
    else
      {
        struct Bytes { unsigned char b[sizeof(T)]; } bytes;
        __builtin_memcpy(bytes.b, input + L::offset(J, Kind::In, sizeof(Mword)),
                         sizeof(T));
        return __builtin_bit_cast(T, bytes);
      }
  }

  template<typename HANDLER>
  static L4_msg_tag
  dispatch(L4_msg_tag tag, Utcb const *in, Utcb *out, HANDLER &&handler)
  {
    static_assert(message_words(L::out_end) <= Utcb::Max_words,
                  "L4_RPC: outputs exceed the message registers");

    if (!check_message_size(tag, L::in_end) || (L::caps && tag.items() < 1))
      return commit_result(-L4_err::EMsgtooshort);

    // The one read of the inputs.  The empty asm makes the compiler treat
    // the copy as changed, so it can never re-read the UTCB in its place.
    Mword snapshot[message_words(L::in_end)];
    __builtin_memcpy(snapshot, in->values, sizeof(snapshot));
    asm volatile ("" : "+m" (snapshot));

    Caps caps;
    if constexpr (L::caps > 0)
      {
        L4_snd_item_iter items(in, tag.words());
        Space *space = ::current()->space();
        // && folds left to right and stops at the first failure.
        if (!(resolve<I, ARGS>(caps, &tag, in, items, space) && ...))
          return tag;
      }

    auto const *input = reinterpret_cast<unsigned char const *>(snapshot);
    auto *output = reinterpret_cast<unsigned char *>(out->values);
    L4_msg_tag const result = handler(argument<I, ARGS>(caps, input, output)...);

    if (result.has_error() || !result.do_switch() || result.proto() < 0)
      return result;

    return L4_msg_tag(message_words(L::out_end), 0, result.raw() & Reply_flags,
                      result.proto());
  }
};

} // namespace Rpc_detail

/// The decoder of a method whose parameters are ARGS.
template<typename ...ARGS>
struct Msg
{
  template<typename HANDLER>
  static L4_msg_tag
  dispatch(L4_msg_tag tag, Utcb const *in, Utcb *out, HANDLER &&handler)
  {
    typedef typename Rpc_detail::Make_indices<sizeof...(ARGS)>::type Indices;
    return Rpc_detail::Rpc<Indices, ARGS...>::dispatch(tag, in, out, handler);
  }
};

/// Msg for the parameters of a method signature.
template<typename SIG> struct Sig_msg;
template<typename ...ARGS>
struct Sig_msg<L4_msg_tag (ARGS...)> : Msg<ARGS...> {};

} // namespace Ko

/**
 * Declare method `name` of a kernel object's protocol, with opcode `opcode`
 * and the parenthesised parameter list `args`.  Msg_<name>::call(o, tag,
 * in, out, extra...) decodes the message and calls
 * o->op_<name>(extra..., arguments...).
 */
#define L4_RPC(opcode, name, args)                                         \
  struct Msg_##name : Ko::Sig_msg<L4_msg_tag args>                        \
  {                                                                       \
    enum : Mword { Opcode = static_cast<Mword>(opcode) };                 \
                                                                          \
    template<typename OBJ, typename ...EXTRA>                             \
    static L4_msg_tag                                                     \
    call(OBJ *o, L4_msg_tag tag, Utcb const *in, Utcb *out,               \
         EXTRA &&...extra)                                                \
    {                                                                     \
      return Ko::Sig_msg<L4_msg_tag args>::dispatch(tag, in, out,         \
        [o, &extra...](auto &&...decoded)                                 \
          {                                                               \
            return o->op_##name(cxx::forward<EXTRA>(extra)...,            \
                                cxx::forward<decltype(decoded)>(decoded)...); \
          });                                                             \
    }                                                                     \
  }
