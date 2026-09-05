module ChessViewTest exposing (suite)

{-| The chessboard: pure update and tap logic, board orientation, and
rendered DOM facts driven by real fixture payloads.
-}

import Dict
import Expect
import FixtureLoader exposing (Fixture)
import Games.Chess.View as View exposing (Msg(..), Out(..))
import Html.Attributes
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (ParamKind(..), Schema)
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, tag, text)


suite : Test
suite =
    describe "chess board"
        [ describe "update"
            [ test "playing a move sends it and clears the selection" <|
                \_ ->
                    let
                        ( m1, out1 ) =
                            View.update (SelectSquare "e2") View.init

                        ( m2, out2 ) =
                            View.update (Play { from = "e2", to = "e4", promotion = Nothing }) m1
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Just "e2") m1.selected
                        , \_ -> Expect.equal NoOut out1
                        , \_ -> Expect.equal Nothing m2.selected
                        , \_ ->
                            Expect.equal
                                (Send (Protocol.encodeAction "move" [ ( "from", E.string "e2" ), ( "to", E.string "e4" ) ]))
                                out2
                        ]
                        ()
            , test "a promotion move carries the piece" <|
                \_ ->
                    View.update (Play { from = "e7", to = "e8", promotion = Just "n" }) View.init
                        |> Tuple.second
                        |> Expect.equal
                            (Send
                                (Protocol.encodeAction "move"
                                    [ ( "from", E.string "e7" ), ( "to", E.string "e8" ), ( "promotion", E.string "n" ) ]
                                )
                            )
            , test "selecting the same piece again clears it" <|
                \_ ->
                    View.init
                        |> View.update (SelectSquare "e2")
                        |> Tuple.first
                        |> View.update (SelectSquare "e2")
                        |> Tuple.first
                        |> .selected
                        |> Expect.equal Nothing
            , test "opening the promotion picker keeps the pawn selected" <|
                \_ ->
                    View.update (OpenPromotion "e7" "e8") View.init
                        |> Tuple.first
                        |> Expect.equal { selected = Just "e7", promoting = Just ( "e7", "e8" ) }
            , test "rematch is reported to the app, not sent as an action" <|
                \_ ->
                    View.update Rematch View.init |> Tuple.second |> Expect.equal WantRematch
            ]
        , describe "tap resolution"
            (let
                base =
                    { selected = Nothing
                    , promoting = False
                    , moves = []
                    , sources = []
                    }

                plain from to =
                    { from = from, to = to, promotion = Nothing }

                promo from to piece =
                    { from = from, to = to, promotion = Just piece }
             in
             [ test "tapping one of my movable pieces selects it" <|
                \_ ->
                    View.resolveTap { base | moves = [ plain "e2" "e4" ], sources = [ "e2" ] } "e2"
                        |> Expect.equal (Just (SelectSquare "e2"))
             , test "tapping an idle square with nothing selected does nothing" <|
                \_ ->
                    View.resolveTap { base | moves = [ plain "e2" "e4" ], sources = [ "e2" ] } "d5"
                        |> Expect.equal Nothing
             , test "with a selection, a legal destination plays that move" <|
                \_ ->
                    View.resolveTap
                        { base
                            | selected = Just "e2"
                            , moves = [ plain "e2" "e4", plain "e2" "e3", plain "g1" "f3" ]
                            , sources = [ "e2", "g1" ]
                        }
                        "e4"
                        |> Expect.equal (Just (Play (plain "e2" "e4")))
             , test "with a selection, tapping the selected square clears it" <|
                \_ ->
                    View.resolveTap { base | selected = Just "e2", moves = [ plain "e2" "e4" ], sources = [ "e2" ] } "e2"
                        |> Expect.equal (Just Clear)
             , test "with a selection, tapping another of my pieces switches to it" <|
                \_ ->
                    View.resolveTap
                        { base
                            | selected = Just "e2"
                            , moves = [ plain "e2" "e4", plain "g1" "f3" ]
                            , sources = [ "e2", "g1" ]
                        }
                        "g1"
                        |> Expect.equal (Just (SelectSquare "g1"))
             , test "with a selection, tapping an idle square clears it" <|
                \_ ->
                    View.resolveTap { base | selected = Just "e2", moves = [ plain "e2" "e4" ], sources = [ "e2" ] } "d5"
                        |> Expect.equal (Just Clear)
             , test "four promotion candidates open the picker instead of playing" <|
                \_ ->
                    View.resolveTap
                        { base
                            | selected = Just "e7"
                            , moves = [ promo "e7" "e8" "q", promo "e7" "e8" "r", promo "e7" "e8" "b", promo "e7" "e8" "n" ]
                            , sources = [ "e7" ]
                        }
                        "e8"
                        |> Expect.equal (Just (OpenPromotion "e7" "e8"))
             , test "any board tap closes an open promotion picker" <|
                \_ ->
                    View.resolveTap
                        { base | selected = Just "e7", promoting = True, moves = [ promo "e7" "e8" "q" ], sources = [ "e7" ] }
                        "e8"
                        |> Expect.equal (Just Clear)
             ]
            )
        , describe "orientation"
            [ test "White sees rank 8 at the top" <|
                \_ -> View.ranksFor "white" |> Expect.equal [ 8, 7, 6, 5, 4, 3, 2, 1 ]
            , test "Black sees rank 1 at the top" <|
                \_ -> View.ranksFor "black" |> Expect.equal [ 1, 2, 3, 4, 5, 6, 7, 8 ]
            ]
        , describe "rendering fixtures" (List.map perFixture (FixtureLoader.byGame "chess"))
        ]


ctx : String -> Protocol.Update -> View.Model -> View.Ctx
ctx playerId update model =
    { playerId = playerId
    , scene = update.scene
    , legal = update.legal
    , model = model
    , clock = Nothing
    , receivedAt = 0
    , now = 0
    , nameOf = identity
    , rematchReady = []
    , away = []
    , finished =
        case update.outcome of
            Protocol.Finished winners ->
                Just winners

            Protocol.Ongoing ->
                Nothing
    }


moveSchemas : List Schema -> List View.Move
moveSchemas =
    View.movesOf


unique : List comparable -> List comparable
unique =
    List.foldl
        (\x acc ->
            if List.member x acc then
                acc

            else
                x :: acc
        )
        []


perFixture : Fixture -> Test
perFixture fixture =
    let
        p1Views =
            (fixture.initial :: List.map .updates fixture.steps) |> List.filterMap (Dict.get "p1")

        p2Views =
            (fixture.initial :: List.map .updates fixture.steps) |> List.filterMap (Dict.get "p2")

        render playerId u =
            View.view (ctx playerId u View.init) |> Query.fromHtml
    in
    describe fixture.name
        [ test "the board is always all sixty-four squares" <|
            \_ ->
                (p1Views |> List.take 8)
                    |> List.map (\u -> render "p1" u |> Query.findAll [ class "chess-sq" ] |> Query.count (Expect.equal 64))
                    |> allPass
        , test "every piece the scene sends is on the board" <|
            \_ ->
                (p1Views |> List.take 8)
                    |> List.map
                        (\u ->
                            render "p1" u
                                |> Query.findAll [ class "chess-piece" ]
                                |> Query.count (Expect.equal (Protocol.zoneTokens "board" u.scene |> List.length))
                        )
                    |> allPass
        , test "White sits at the bottom for p1 and Black for p2" <|
            \_ ->
                case ( p1Views, p2Views ) of
                    ( u1 :: _, u2 :: _ ) ->
                        Expect.all
                            [ \_ ->
                                render "p1" u1
                                    |> Query.findAll [ class "chess-sq" ]
                                    |> Query.first
                                    |> Query.has [ attribute (Html.Attributes.attribute "data-square" "a8") ]
                            , \_ ->
                                render "p2" u2
                                    |> Query.findAll [ class "chess-sq" ]
                                    |> Query.first
                                    |> Query.has [ attribute (Html.Attributes.attribute "data-square" "h1") ]
                            ]
                            ()

                    _ ->
                        Expect.pass
        , test "a waiting player is told whose turn it is" <|
            \_ ->
                p2Views
                    |> List.filter (\u -> (Protocol.sceneData (D.nullable D.string) "to_move" u.scene |> Maybe.withDefault Nothing) == Just "p1")
                    |> List.take 6
                    |> List.map (\u -> render "p2" u |> Query.has [ text "WAITING FOR P1" ])
                    |> allPass
        , test "clicking one of my movable pieces selects it" <|
            \_ ->
                p1Views
                    |> List.filter (\u -> moveSchemas u.legal /= [])
                    |> List.head
                    |> Maybe.map
                        (\u ->
                            let
                                from =
                                    moveSchemas u.legal |> List.map .from |> List.head |> Maybe.withDefault ""
                            in
                            render "p1" u
                                |> Query.find [ class "chess-sq", attribute (Html.Attributes.attribute "data-square" from) ]
                                |> Event.simulate Event.click
                                |> Event.expect (SelectSquare from)
                        )
                    |> Maybe.withDefault Expect.pass
        , test "selecting a piece shows a hint on each destination square" <|
            \_ ->
                p1Views
                    |> List.filter (\u -> moveSchemas u.legal /= [])
                    |> List.head
                    |> Maybe.map
                        (\u ->
                            let
                                from =
                                    moveSchemas u.legal |> List.map .from |> List.head |> Maybe.withDefault ""

                                destinations =
                                    moveSchemas u.legal
                                        |> List.filter (\m -> m.from == from)
                                        |> List.map .to
                                        |> unique
                                        |> List.length
                            in
                            View.view (ctx "p1" u { selected = Just from, promoting = Nothing })
                                |> Query.fromHtml
                                |> Query.findAll [ class "chess-hint" ]
                                |> Query.count (Expect.equal destinations)
                        )
                    |> Maybe.withDefault Expect.pass
        , test "the promotion picker offers the four pieces" <|
            \_ ->
                p1Views
                    |> List.head
                    |> Maybe.map
                        (\u ->
                            View.view (ctx "p1" u { selected = Just "e7", promoting = Just ( "e7", "e8" ) })
                                |> Query.fromHtml
                                |> Expect.all
                                    [ Query.has [ text "PROMOTE TO" ]
                                    , Query.findAll [ tag "button", attribute (Html.Attributes.attribute "data-promote" "q") ]
                                        >> Query.count (Expect.equal 1)
                                    , Query.findAll [ attribute (Html.Attributes.attribute "data-promote" "") ]
                                        >> Query.count (Expect.equal 0)
                                    ]
                        )
                    |> Maybe.withDefault Expect.pass
        , test "picking the knight sends the underpromotion" <|
            \_ ->
                p1Views
                    |> List.head
                    |> Maybe.map
                        (\u ->
                            View.view (ctx "p1" u { selected = Just "e7", promoting = Just ( "e7", "e8" ) })
                                |> Query.fromHtml
                                |> Query.find [ tag "button", attribute (Html.Attributes.attribute "data-promote" "n") ]
                                |> Event.simulate Event.click
                                |> Event.expect (Play { from = "e7", to = "e8", promotion = Just "n" })
                        )
                    |> Maybe.withDefault Expect.pass
        , test "the game-over panel offers a rematch once the game is decided" <|
            \_ ->
                p1Views
                    |> List.filter (\u -> u.outcome /= Protocol.Ongoing)
                    |> List.map (\u -> render "p1" u |> Query.has [ text "REMATCH" ])
                    |> allPass
        ]


{-| `Expect.all` rejects an empty list; a fixture that never reaches a state
is not a failure of the renderer.
-}
allPass : List Expect.Expectation -> Expect.Expectation
allPass expectations =
    case expectations of
        [] ->
            Expect.pass

        _ ->
            Expect.all (List.map always expectations) ()
