module PuzzleFixtures exposing (bar, doubles, hit, off)

{-| Four puzzles, written by hand against the wire contract (puzzles-wire):
what `GET /papi/puzzles/:id` answers, board, tree and all.

They are positions, not recordings: each one was worked out at the board
and then checked -- fifteen checkers a side in every node, every child
naming a node the tree holds, and `terminal` exactly where there are no
children. Between them they cover a hit, an entry from the bar, bearing
off, doubles, the larger-die rule, and two orders of the same checkers
arriving at one node.

The mover is White and the points are numbered from their side: they run
24 -> 1, enter from the bar onto 24..19 and bear off from 6..1.

-}

{-| White on the bar against a 6-3. Only the 6 enters (the 3's point is
open but nothing can follow it), so the larger die must be played and
the root offers that one child; the turn is over with the 3 standing.
-}
bar : String
bar =
    """{"ok":true,"id":"bar00001","kind":"move","question":{"board":{"white":{"points":[0,0,0,4,5,5,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"bar":1,"off":0},"black":{"points":[2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,2,2,0,3,0],"bar":0,"off":0}},"dice":[6,3],"cube":{"value":1,"owner":"center"},"score":null,"crawford":false,"jacoby":false},"tree":{"root":"r","nodes":{"r":{"board":{"white":{"points":[0,0,0,4,5,5,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"bar":1,"off":0},"black":{"points":[2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,2,2,0,3,0],"bar":0,"off":0}},"dice_left":[6,3],"terminal":false,"moved":null,"children":[{"die":6,"from":"bar","to":"19","node":"n1"}]},"n1":{"board":{"white":{"points":[0,0,0,4,5,5,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,2,2,0,3,0],"bar":0,"off":0}},"dice_left":[3],"terminal":true,"moved":{"from":"bar","to":"19","hit":false},"children":[]}}},"prompt":"White to play 6-3. What's your play?"}"""

{-| 3-3 with the home board shut, so the two runners walk 13/10/7/4 and
the four threes can be spread over them in every order: eight boards,
nine steps, two of the boards reached two ways.
-}
doubles : String
doubles =
    """{"ok":true,"id":"dbl00001","kind":"move","question":{"board":{"white":{"points":[0,0,0,4,4,5,0,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,3,0,3],"bar":0,"off":0}},"dice":[3,3],"cube":{"value":1,"owner":"center"},"score":null,"crawford":false,"jacoby":false},"tree":{"root":"r","nodes":{"r":{"board":{"white":{"points":[0,0,0,4,4,5,0,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,3,0,3],"bar":0,"off":0}},"dice_left":[3,3,3,3],"terminal":false,"moved":null,"children":[{"die":3,"from":"13","to":"10","node":"n1"}]},"n1":{"board":{"white":{"points":[0,0,0,4,4,5,0,0,0,1,0,0,1,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,3,0,3],"bar":0,"off":0}},"dice_left":[3,3,3],"terminal":false,"moved":{"from":"13","to":"10","hit":false},"children":[{"die":3,"from":"13","to":"10","node":"n2b"},{"die":3,"from":"10","to":"7","node":"n2a"}]},"n2a":{"board":{"white":{"points":[0,0,0,4,4,5,1,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,3,0,3],"bar":0,"off":0}},"dice_left":[3,3],"terminal":false,"moved":{"from":"10","to":"7","hit":false},"children":[{"die":3,"from":"13","to":"10","node":"n3b"},{"die":3,"from":"7","to":"4","node":"n3a"}]},"n2b":{"board":{"white":{"points":[0,0,0,4,4,5,0,0,0,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,3,0,3],"bar":0,"off":0}},"dice_left":[3,3],"terminal":false,"moved":{"from":"13","to":"10","hit":false},"children":[{"die":3,"from":"10","to":"7","node":"n3b"}]},"n3a":{"board":{"white":{"points":[0,0,0,5,4,5,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,3,0,3],"bar":0,"off":0}},"dice_left":[3],"terminal":false,"moved":{"from":"7","to":"4","hit":false},"children":[{"die":3,"from":"13","to":"10","node":"n4a"}]},"n3b":{"board":{"white":{"points":[0,0,0,4,4,5,1,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,3,0,3],"bar":0,"off":0}},"dice_left":[3],"terminal":false,"moved":{"from":"13","to":"10","hit":false},"children":[{"die":3,"from":"10","to":"7","node":"n4b"},{"die":3,"from":"7","to":"4","node":"n4a"}]},"n4a":{"board":{"white":{"points":[0,0,0,5,4,5,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,3,0,3],"bar":0,"off":0}},"dice_left":[],"terminal":true,"moved":{"from":"7","to":"4","hit":false},"children":[]},"n4b":{"board":{"white":{"points":[0,0,0,4,4,5,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,3,0,3],"bar":0,"off":0}},"dice_left":[],"terminal":true,"moved":{"from":"10","to":"7","hit":false},"children":[]}}},"prompt":"White to play 3-3. What's your play?"}"""

{-| White to play 6-4 with two checkers on 13 and everything else shut
in: the 6 hits the blot on 7, the 4 runs to 9, and playing them in
either order reaches the same board (`n3`).
-}
hit : String
hit =
    """{"ok":true,"id":"hit00001","kind":"move","question":{"board":{"white":{"points":[0,0,0,4,4,5,0,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,0,0,0,0,1,0,0,0,0,0,0,0,0,0,3,3,0,2,2,0,0,0],"bar":0,"off":0}},"dice":[6,4],"cube":{"value":1,"owner":"center"},"score":null,"crawford":false,"jacoby":false},"tree":{"root":"r","nodes":{"r":{"board":{"white":{"points":[0,0,0,4,4,5,0,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,0,0,0,0,1,0,0,0,0,0,0,0,0,0,3,3,0,2,2,0,0,0],"bar":0,"off":0}},"dice_left":[6,4],"terminal":false,"moved":null,"children":[{"die":6,"from":"13","to":"7","node":"n1"},{"die":4,"from":"13","to":"9","node":"n2"}]},"n1":{"board":{"white":{"points":[0,0,0,4,4,5,1,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,3,0,2,2,0,0,0],"bar":1,"off":0}},"dice_left":[4],"terminal":false,"moved":{"from":"13","to":"7","hit":true},"children":[{"die":4,"from":"13","to":"9","node":"n3"},{"die":4,"from":"7","to":"3","node":"n4"}]},"n2":{"board":{"white":{"points":[0,0,0,4,4,5,0,0,1,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,0,0,0,0,1,0,0,0,0,0,0,0,0,0,3,3,0,2,2,0,0,0],"bar":0,"off":0}},"dice_left":[6],"terminal":false,"moved":{"from":"13","to":"9","hit":false},"children":[{"die":6,"from":"13","to":"7","node":"n3"},{"die":6,"from":"9","to":"3","node":"n5"}]},"n3":{"board":{"white":{"points":[0,0,0,4,4,5,1,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,3,0,2,2,0,0,0],"bar":1,"off":0}},"dice_left":[],"terminal":true,"moved":{"from":"13","to":"7","hit":true},"children":[]},"n4":{"board":{"white":{"points":[0,0,1,4,4,5,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,3,0,2,2,0,0,0],"bar":1,"off":0}},"dice_left":[],"terminal":true,"moved":{"from":"7","to":"3","hit":false},"children":[]},"n5":{"board":{"white":{"points":[0,0,1,4,4,5,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,0,0,0,0,1,0,0,0,0,0,0,0,0,0,3,3,0,2,2,0,0,0],"bar":0,"off":0}},"dice_left":[],"terminal":true,"moved":{"from":"9","to":"3","hit":false},"children":[]}}},"prompt":"White to play 6-4. What's your play?"}"""

{-| Two checkers left and a 5-2, both of which bear the one on point 2
off. Whichever is spent first, the last checker comes off to the same
node (`c`).
-}
off : String
off =
    """{"ok":true,"id":"off00001","kind":"move","question":{"board":{"white":{"points":[1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":13},"black":{"points":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,0,5,0,5],"bar":0,"off":0}},"dice":[5,2],"cube":{"value":1,"owner":"center"},"score":null,"crawford":false,"jacoby":false},"tree":{"root":"r","nodes":{"r":{"board":{"white":{"points":[1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":13},"black":{"points":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,0,5,0,5],"bar":0,"off":0}},"dice_left":[5,2],"terminal":false,"moved":null,"children":[{"die":5,"from":"2","to":"off","node":"a"},{"die":2,"from":"2","to":"off","node":"b"}]},"a":{"board":{"white":{"points":[1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":14},"black":{"points":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,0,5,0,5],"bar":0,"off":0}},"dice_left":[2],"terminal":false,"moved":{"from":"2","to":"off","hit":false},"children":[{"die":2,"from":"1","to":"off","node":"c"}]},"b":{"board":{"white":{"points":[1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":14},"black":{"points":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,0,5,0,5],"bar":0,"off":0}},"dice_left":[5],"terminal":false,"moved":{"from":"2","to":"off","hit":false},"children":[{"die":5,"from":"1","to":"off","node":"c"}]},"c":{"board":{"white":{"points":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":15},"black":{"points":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,0,5,0,5],"bar":0,"off":0}},"dice_left":[],"terminal":true,"moved":{"from":"1","to":"off","hit":false},"children":[]}}},"prompt":"White to play 5-2. What's your play?"}"""
