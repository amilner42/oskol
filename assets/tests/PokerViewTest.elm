module PokerViewTest exposing (suite)

{-| The poker table: pure update logic and rendered DOM facts, driven by
real fixture payloads.
-}

import Dict
import Expect
import FixtureLoader exposing (Fixture)
import Games.Poker.View as View exposing (Msg(..), Out(..))
import Json.Decode as D
import Json.Encode as E
import Protocol
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, id, tag, text)
import Html.Attributes


suite : Test
suite =
    describe "poker table"
        [ describe "update"
            [ test "simple actions send their name" <|
                \_ ->
                    View.update (Simple "fold") View.init
                        |> Tuple.second
                        |> Expect.equal (Send (Protocol.encodeAction "fold" []))
            , test "a sized action carries the amount" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            View.update (SetAmount "150") View.init

                        ( m2, out ) =
                            View.update (SendAmount "raise" 150) m1
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Just 150) m1.amount
                        , \_ -> Expect.equal Nothing m2.amount
                        , \_ -> Expect.equal (Send (Protocol.encodeAction "raise" [ ( "amount", E.int 150 ) ])) out
                        ]
                        ()
            , test "garbage in the amount box is ignored" <|
                \_ ->
                    View.update (SetAmount "lots") View.init |> Tuple.first |> .amount |> Expect.equal Nothing
            , test "rematch is reported to the app" <|
                \_ ->
                    View.update Rematch View.init |> Tuple.second |> Expect.equal WantRematch
            ]
        , describe "rendering fixtures" (List.map perFixture (FixtureLoader.byGame "poker"))
        ]


ctx : String -> Protocol.Update -> View.Model -> View.Ctx
ctx playerId update model =
    { playerId = playerId
    , scene = update.scene
    , legal = update.legal
    , model = model
    , clock = Just update.clock
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


has : String -> List Protocol.Schema -> Bool
has name legal =
    List.any (\s -> s.name == name) legal


allPass : List Expect.Expectation -> Expect.Expectation
allPass expectations =
    case expectations of
        [] ->
            Expect.pass

        _ ->
            Expect.all (List.map always expectations) ()


perFixture : Fixture -> Test
perFixture fixture =
    let
        views =
            (fixture.initial :: List.map .updates fixture.steps) |> List.filterMap (Dict.get "p1")

        render u =
            View.view (ctx "p1" u View.init) |> Query.fromHtml

        cardsIn u seat =
            Protocol.zoneTokens ("hole:" ++ seat) u.scene |> List.length

        hiddenIn u seat =
            Protocol.findZone ("hole:" ++ seat) u.scene
                |> Maybe.map (\z -> if List.isEmpty z.tokens then z.count else 0)
                |> Maybe.withDefault 0
    in
    describe fixture.name
        [ test "my cards are faces, the opponent's are backs unless shown" <|
            \_ ->
                views
                    |> List.map
                        (\u ->
                            render u
                                |> Expect.all
                                    [ Query.find [ attribute (Html.Attributes.attribute "data-seat" "p1") ]
                                        >> Query.findAll [ class "pcard" ]
                                        >> Query.count (Expect.equal (cardsIn u "p1"))
                                    , Query.find [ attribute (Html.Attributes.attribute "data-seat" "p2") ]
                                        >> Query.findAll [ attribute (Html.Attributes.attribute "data-card" "back") ]
                                        >> Query.count (Expect.equal (hiddenIn u "p2"))
                                    , Query.find [ attribute (Html.Attributes.attribute "data-seat" "p2") ]
                                        >> Query.findAll [ class "pcard" ]
                                        >> Query.count (Expect.equal (cardsIn u "p2" + hiddenIn u "p2"))
                                    ]
                        )
                    |> allPass
        , test "the board shows every community card and five slots in all" <|
            \_ ->
                views
                    |> List.map
                        (\u ->
                            render u
                                |> Query.find [ id "board" ]
                                |> Query.findAll [ class "pcard" ]
                                |> Query.count (Expect.equal 5)
                        )
                    |> allPass
        , test "the action buttons follow the legal actions" <|
            \_ ->
                views
                    |> List.map
                        (\u ->
                            let
                                expectButton label present =
                                    Query.findAll [ tag "button", text label ]
                                        >> Query.count
                                            (Expect.equal
                                                (if present then
                                                    1

                                                 else
                                                    0
                                                )
                                            )
                            in
                            render u
                                |> Expect.all
                                    [ expectButton "FOLD" (has "fold" u.legal)
                                    , expectButton "CHECK" (has "check" u.legal)
                                    , expectButton "NEXT HAND ▶" (has "deal" u.legal && u.outcome == Protocol.Ongoing)
                                    , Query.findAll [ id "size-slider" ]
                                        >> Query.count
                                            (Expect.equal
                                                (if has "bet" u.legal || has "raise" u.legal then
                                                    1

                                                 else
                                                    0
                                                )
                                            )
                                    ]
                        )
                    |> allPass
        , test "the slider is bounded by the schema and starts at the minimum" <|
            \_ ->
                views
                    |> List.filterMap (\u -> View.sizing u.legal |> Maybe.map (\s -> ( u, s )))
                    |> List.map
                        (\( u, s ) ->
                            render u
                                |> Query.find [ id "size-slider" ]
                                |> Query.has
                                    [ attribute (Html.Attributes.min (String.fromInt s.min))
                                    , attribute (Html.Attributes.max (String.fromInt s.max))
                                    , attribute (Html.Attributes.value (String.fromInt s.min))
                                    ]
                        )
                    |> allPass
        , test "only the next button auto-deals, and only between hands" <|
            \_ ->
                views
                    |> List.map
                        (\u ->
                            let
                                t =
                                    View.table u.scene

                                expected =
                                    t.phase == "hand_over" && t.nextButton == "p1" && has "deal" u.legal && u.outcome == Protocol.Ongoing
                            in
                            Expect.equal expected (View.wantsAutoDeal (ctx "p1" u View.init))
                        )
                    |> allPass
        , test "the pot on screen is the pot in the scene" <|
            \_ ->
                views
                    |> List.map
                        (\u ->
                            render u
                                |> Query.find [ id "pot" ]
                                |> Query.has [ text ("POT " ++ String.fromInt (Protocol.sceneData D.int "pot" u.scene |> Maybe.withDefault 0)) ]
                        )
                    |> allPass
        ]
