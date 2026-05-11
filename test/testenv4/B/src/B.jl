module B

import A

struct Foo end

# Cross-package overload — issue #161. B extends A.foo for its own type
# without re-exporting the name. The overload must be captured in B's
# cache as a FunctionStore that extends A.foo.
A.foo(::Foo) = 2

end # module B
