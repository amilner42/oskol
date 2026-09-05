module GenericViewTest exposing (suite)

{-| The generic renderer: the interaction model every new game gets for free.
-}

import Dict
import Expect
import FixtureLoader
import Generic.View as View exposing (Msg(..))
import Html
import Json.Encode as E
import Protocol exposing (ParamKind(..), Schema)
import Html.Attributes exposing (title)
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, style, tag, text)


simple : Schema
simple =
    { name = "roll", label = "Roll dice", params = [] }


selecting : Schema
selecting =
    { name = "play_hand", label = "Play hand", params = [ { name = "cards", kind = Select { zone = "hand:p1", candidates = [ "AS", "KD" ], min = 1, max = 5 } } ] }


choosing : Schema
choosing =
    { name = "pick", label = "Pick", params = [ { name = "which", kind = Choice [ ( "a", "A" ), ( "b", "B" ) ] } ] }


suite : Test
suite =
    describe "generic renderer"
        [ test "a schema with nothing to choose fires on click" <|
            \_ ->
                View.update (ChooseAction 0 simple) View.init
                    |> Tuple.second
                    |> Expect.equal (Just (Protocol.encodeAction "roll" []))
        , test "a select schema waits for tokens and a confirm" <|
            \_ ->
                let
                    ( m1, out1 ) =
                        View.update (ChooseAction 0 selecting) View.init

                    ( m2, _ ) =
                        View.update (ToggleToken "AS") m1

                    ( m3, _ ) =
                        View.update (ToggleToken "KD") m2

                    ( _, out3 ) =
                        View.update (Submit selecting) m3
                in
                Expect.all
                    [ \_ -> Expect.equal Nothing out1
                    , \_ -> Expect.equal (Just 0) m1.activeAction
                    , \_ -> Expect.equal (Just (Protocol.encodeAction "play_hand" [ ( "cards", E.list E.string [ "AS", "KD" ] ) ])) out3
                    ]
                    ()
        , test "toggling a token twice deselects it" <|
            \_ ->
                View.init
                    |> View.update (ToggleToken "AS")
                    |> Tuple.first
                    |> View.update (ToggleToken "AS")
                    |> Tuple.first
                    |> .selected
                    |> Expect.equal View.init.selected
        , test "a multi-option choice waits for the option, then sends it" <|
            \_ ->
                let
                    ( m1, out1 ) =
                        View.update (ChooseAction 0 choosing) View.init

                    ( m2, _ ) =
                        View.update (ChooseOption "which" "b") m1

                    ( _, out2 ) =
                        View.update (Submit choosing) m2
                in
                Expect.all
                    [ \_ -> Expect.equal Nothing out1
                    , \_ -> Expect.equal (Just (Protocol.encodeAction "pick" [ ( "which", E.string "b" ) ])) out2
                    ]
                    ()
        , test "cancel clears everything" <|
            \_ ->
                View.init
                    |> View.update (ChooseAction 0 selecting)
                    |> Tuple.first
                    |> View.update (ToggleToken "AS")
                    |> Tuple.first
                    |> View.update Cancel
                    |> Tuple.first
                    |> Expect.equal View.init
        , test "a grid zone is laid out as a grid with tokens at their positions" <|
            \_ ->
                View.view
                    { playerId = "p1"
                    , scene = gridScene
                    , legal = [ placing ]
                    , model = View.init
                    , clock = Nothing
                    , receivedAt = 0
                    , now = 0
                    , nameOf = identity
                    , finished = Nothing
                    , away = []
                    }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ style "display" "grid" ]
                        , Query.has [ style "grid-template-columns" "repeat(3, 1.65rem)" ]
                        , Query.has [ style "grid-column" "2", style "grid-row" "3" ]
                        ]
        , test "an intersections grid draws board lines on wood and bare tap targets" <|
            \_ ->
                let
                    rendered =
                        View.view
                            { playerId = "p1"
                            , scene = gobanScene
                            , legal = [ placing ]
                            , model = View.init
                            , clock = Nothing
                            , receivedAt = 0
                            , now = 0
                            , nameOf = identity
                            , finished = Nothing
                            , away = []
                            }
                            |> Query.fromHtml
                in
                Expect.all
                    [ -- The goban ground, no cell gaps.
                      Query.has [ style "background" "#dcb35c", style "gap" "0" ]

                    -- The empty crossing is a tap target, not a disc or card.
                    , Query.find [ tag "button", attribute (title "p1-2") ]
                        >> Query.hasNot [ class "checker" ]

                    -- The stone still renders as a disc.
                    , Query.find [ tag "button", attribute (title "s1") ]
                        >> Query.has [ class "checker" ]

                    -- A star point dot is drawn on the declared crossing.
                    , Query.has [ style "width" "5px", style "height" "5px" ]
                    ]
                    rendered
        , describe "renders every fixture scene" (List.map renders FixtureLoader.all)
        ]


gobanScene : Protocol.Scene
gobanScene =
    let
        withStyle =
            E.object
                [ ( "grid_style", E.string "intersections" )
                , ( "star_points", E.list (\( c, r ) -> E.list E.int [ c, r ]) [ ( 1, 2 ) ] )
                ]
    in
    { gridScene
        | data = withStyle
        , zones =
            List.map
                (\zone ->
                    { zone
                        | tokens =
                            List.map
                                (\token ->
                                    if token.kind == "point" then
                                        { token | props = E.object [] }

                                    else
                                        token
                                )
                                zone.tokens
                    }
                )
                gridScene.zones
    }


placing : Schema
placing =
    { name = "place"
    , label = "Place a stone"
    , params = [ { name = "point", kind = Select { zone = "board", candidates = [ "p1-2" ], min = 1, max = 1 } } ]
    }


gridScene : Protocol.Scene
gridScene =
    { game = "go"
    , phase = "playing"
    , viewer = Just "p1"
    , players =
        [ { id = "p1", name = "Alice", counters = Dict.empty, flags = [ "to_move" ], data = E.object [] }
        , { id = "p2", name = "Bob", counters = Dict.empty, flags = [], data = E.object [] }
        ]
    , zones =
        [ { id = "board"
          , owner = Nothing
          , layout = Protocol.Grid 3 3
          , tokens =
                [ { id = "s1", kind = "stone", faceUp = True, position = Just ( 0, 0 ), props = E.object [ ( "color", E.string "black" ) ] }
                , { id = "p1-2", kind = "point", faceUp = True, position = Just ( 1, 2 ), props = E.object [ ( "color", E.string "#c8a05f" ) ] }
                ]
          , count = 2
          }
        ]
    , data = E.object []
    }


renders : FixtureLoader.Fixture -> Test
renders fixture =
    test fixture.name <|
        \_ ->
            fixture.initial
                |> Dict.get "p1"
                |> Maybe.map
                    (\u ->
                        View.view { playerId = "p1", scene = u.scene, legal = u.legal, model = View.init, clock = Nothing, receivedAt = 0, now = 0, nameOf = identity, finished = Nothing, away = [] }
                            |> Query.fromHtml
                            |> Expect.all
                                [ Query.findAll [ tag "button" ] >> Query.count (Expect.atLeast (List.length u.legal))
                                , Query.has [ text "Alice" ]
                                , Query.has [ text "Bob" ]
                                ]
                    )
                |> Maybe.withDefault (Expect.fail "no p1 view")
