# ===----------------------------------------------------------------------=== #
# Copyright (c) 2025, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Defines InlinedFixedVector.

You can import these APIs from the `collections` package. For example:

```mojo
from collections import InlinedFixedVector
```
"""

from sys import sizeof
from sys.intrinsics import _type_is_eq

from memory import Pointer, UnsafePointer, memcpy

from utils import StaticTuple

# ===-----------------------------------------------------------------------===#
# _VecIter
# ===-----------------------------------------------------------------------===#


@value
struct _VecIter[
    type: AnyTrivialRegType,
    vec_type: AnyType,
    deref: fn (UnsafePointer[vec_type], Int) -> type,
](Sized):
    """Iterator for any random-access container"""

    var i: Int
    var size: Int
    var vec: UnsafePointer[vec_type]

    fn __next__(mut self) -> type:
        self.i += 1
        return deref(self.vec, self.i - 1)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self.__len__() > 0

    fn __len__(self) -> Int:
        return self.size - self.i


# ===-----------------------------------------------------------------------===#
# InlinedFixedVector
# ===-----------------------------------------------------------------------===#


@always_inline
fn _calculate_fixed_vector_default_size[type: AnyTrivialRegType]() -> Int:
    alias prefered_bytecount = 64
    alias sizeof_type = sizeof[type]()

    @parameter
    if sizeof_type >= 256:
        return 0

    alias prefered_inline_bytes = prefered_bytecount - sizeof[
        InlinedFixedVector[type, 0]
    ]()
    alias num_elements = prefered_inline_bytes // sizeof_type
    return num_elements or 1


struct InlinedFixedVector[
    type: AnyTrivialRegType,
    size: Int = _calculate_fixed_vector_default_size[type](),
](Sized, ExplicitlyCopyable):
    """A dynamically-allocated vector with small-vector optimization and a fixed
    maximum capacity.

    The `InlinedFixedVector` does not resize or implement bounds checks. It is
    initialized with both a small-vector size (specified at compile time) and a
    maximum capacity (specified at runtime).

    The first `size` elements are stored in the statically-allocated small
    vector storage. Any remaining elements are stored in dynamically-allocated
    storage.

    When it is deallocated, it frees its memory.

    TODO: It should call its element destructors once we have traits.

    This data structure is useful for applications where the number of required
    elements is not known at compile time, but once known at runtime, is
    guaranteed to be equal to or less than a certain capacity.

    Parameters:
        type: The type of the elements.
        size: The statically-known small-vector size.
    """

    alias static_size: Int = size
    alias static_data_type = StaticTuple[type, size]
    var static_data: Self.static_data_type
    """The underlying static storage, used for small vectors."""
    var dynamic_data: UnsafePointer[type]
    """The underlying dynamic storage, used to grow large vectors."""
    var current_size: Int
    """The number of elements in the vector."""
    var capacity: Int
    """The maximum number of elements that can fit in the vector."""

    @always_inline
    @implicit
    fn __init__(out self, capacity: Int):
        """Constructs `InlinedFixedVector` with the given capacity.

        The dynamically allocated portion is `capacity - size`.

        Args:
            capacity: The requested maximum capacity of the vector.
        """
        self.static_data = Self.static_data_type()  # Undef initialization
        self.dynamic_data = UnsafePointer[type]()
        if capacity > Self.static_size:
            self.dynamic_data = UnsafePointer[type].alloc(capacity - size)
        self.current_size = 0
        self.capacity = capacity

    @always_inline
    fn copy(self) -> Self:
        """
        Copy constructor.

        Returns:
            A copy of the value.
        """
        var copy = Self(capacity=self.capacity)

        copy.static_data = self.static_data
        copy.dynamic_data = UnsafePointer[type]()
        if self.dynamic_data:
            var ext_len = self.capacity - size
            copy.dynamic_data = UnsafePointer[type].alloc(ext_len)
            memcpy(copy.dynamic_data, self.dynamic_data, ext_len)

        copy.current_size = self.current_size
        copy.capacity = self.capacity

        return copy^

    @always_inline
    fn __moveinit__(out self, owned existing: Self):
        """
        Move constructor.

        Args:
            existing: The `InlinedFixedVector` to consume.
        """
        self.static_data = existing.static_data
        self.dynamic_data = existing.dynamic_data
        self.current_size = existing.current_size
        self.capacity = existing.capacity

        existing.dynamic_data = UnsafePointer[type]()

    @always_inline
    fn __del__(owned self):
        """
        Destructor.
        """
        if self.dynamic_data:
            self.dynamic_data.free()
            self.dynamic_data = UnsafePointer[type]()

    @always_inline
    fn append(mut self, value: type):
        """Appends a value to this vector.

        Args:
            value: The value to append.
        """
        debug_assert(
            self.current_size < self.capacity,
            "index must be less than capacity",
        )
        if self.current_size < Self.static_size:
            self.static_data[self.current_size] = value
        else:
            self.dynamic_data[self.current_size - Self.static_size] = value
        self.current_size += 1

    @always_inline
    fn __len__(self) -> Int:
        """Gets the number of elements in the vector.

        Returns:
            The number of elements in the vector.
        """
        return self.current_size

    @always_inline
    fn __getitem__[I: Indexer](self, idx: I) -> type:
        """Gets a vector element at the given index.

        Args:
            idx: The index of the element.

        Parameters:
            I: A type that can be used as an index.

        Returns:
            The element at the given index.
        """
        var index = Int(idx)
        debug_assert(
            -self.current_size <= index < self.current_size,
            "index must be within bounds",
        )

        @parameter
        if not _type_is_eq[I, UInt]():
            if index < 0:
                index += len(self)

        if index < Self.static_size:
            return self.static_data[index]

        return self.dynamic_data[index - Self.static_size]

    @always_inline
    fn __setitem__[I: Indexer](mut self, idx: I, value: type):
        """Sets a vector element at the given index.

        Parameters:
            I: A type that can be used as an index.

        Args:
            idx: The index of the element.
            value: The value to assign.
        """
        var index = Int(idx)
        debug_assert(
            -self.current_size <= index < self.current_size,
            "index must be within bounds",
        )

        @parameter
        if not _type_is_eq[I, UInt]():
            if index < 0:
                index += len(self)

        if index < Self.static_size:
            self.static_data[index] = value
        else:
            self.dynamic_data[index - Self.static_size] = value

    fn clear(mut self):
        """Clears the elements in the vector."""
        self.current_size = 0

    @staticmethod
    fn _deref_iter_impl(selfptr: UnsafePointer[Self], i: Int, /) -> type:
        return selfptr[][i]

    alias _iterator = _VecIter[type, Self, Self._deref_iter_impl]

    fn __iter__(mut self) -> Self._iterator:
        """Iterate over the vector.

        Returns:
            An iterator to the start of the vector.
        """
        return Self._iterator(
            0, self.current_size, UnsafePointer.address_of(self)
        )
