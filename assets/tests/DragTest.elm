module DragTest exposing (suite)

{-| The press-drag-drop state machine: taps stay taps under the threshold,
drags end in a drop only inside a legal zone, and everything else snaps
back to idle.
-}

import Drag
import Expect
import Test exposing (Test, describe, test)


type Msg
    = Tapped


pressed : Drag.State String Msg
pressed =
    Drag.press { origin = "13", item = "white", tap = Just Tapped, x = 100, y = 100 }


zone : Drag.Zone
zone =
    { loc = "8", left = 200, top = 300, width = 50, height = 120 }


suite : Test
suite =
    describe "drag state machine"
        [ test "a press is not yet a drag" <|
            \_ ->
                Drag.active pressed |> Expect.equal Nothing
        , test "movement under the threshold stays a press" <|
            \_ ->
                pressed
                    |> Drag.move { x = 105, y = 103 }
                    |> Drag.active
                    |> Expect.equal Nothing
        , test "movement past the threshold becomes a drag that follows the pointer" <|
            \_ ->
                pressed
                    |> Drag.move { x = 130, y = 90 }
                    |> Drag.active
                    |> Expect.equal (Just { origin = "13", item = "white", x = 130, y = 90 })
        , test "release under the threshold is the stored tap" <|
            \_ ->
                pressed
                    |> Drag.move { x = 104, y = 104 }
                    |> Drag.release { x = 104, y = 104 }
                    |> Expect.equal ( Drag.idle, Drag.Tap Tapped )
        , test "release of a press with no tap is a no-op" <|
            \_ ->
                Drag.press { origin = "13", item = "white", tap = Nothing, x = 100, y = 100 }
                    |> Drag.release { x = 100, y = 100 }
                    |> Expect.equal ( Drag.idle, Drag.None )
        , test "a drop inside a legal zone names the origin and the zone" <|
            \_ ->
                pressed
                    |> Drag.setZones [ zone ]
                    |> Drag.move { x = 225, y = 360 }
                    |> Drag.release { x = 225, y = 360 }
                    |> Expect.equal ( Drag.idle, Drag.Drop "13" "8" )
        , test "a drop outside every zone snaps back" <|
            \_ ->
                pressed
                    |> Drag.setZones [ zone ]
                    |> Drag.move { x = 150, y = 150 }
                    |> Drag.release { x = 150, y = 150 }
                    |> Expect.equal ( Drag.idle, Drag.None )
        , test "zones may arrive after the threshold has been crossed" <|
            \_ ->
                pressed
                    |> Drag.move { x = 225, y = 360 }
                    |> Drag.setZones [ zone ]
                    |> Drag.release { x = 225, y = 360 }
                    |> Expect.equal ( Drag.idle, Drag.Drop "13" "8" )
        , test "the hovered zone highlights only while the drag is over it" <|
            \_ ->
                let
                    dragging =
                        pressed |> Drag.setZones [ zone ]
                in
                ( dragging |> Drag.move { x = 225, y = 360 } |> Drag.hover
                , dragging |> Drag.move { x = 150, y = 150 } |> Drag.hover
                )
                    |> Expect.equal ( Just "8", Nothing )
        , test "a release out of nowhere stays idle" <|
            \_ ->
                Drag.release { x = 5, y = 5 } Drag.idle
                    |> Expect.equal ( Drag.idle, Drag.None )
        ]
