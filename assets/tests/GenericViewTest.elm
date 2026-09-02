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
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector exposing (class, tag, text)


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
        , describe "renders every fixture scene" (List.map renders FixtureLoader.all)
        ]


renders : FixtureLoader.Fixture -> Test
renders fixture =
    test fixture.name <|
        \_ ->
            fixture.initial
                |> Dict.get "p1"
                |> Maybe.map
                    (\u ->
                        View.view { playerId = "p1", scene = u.scene, legal = u.legal, model = View.init, status = "in progress", clock = Html.text "" }
                            |> Query.fromHtml
                            |> Expect.all
                                [ Query.findAll [ tag "button" ] >> Query.count (Expect.atLeast (List.length u.legal))
                                , Query.has [ text "Alice" ]
                                , Query.has [ text "Bob" ]
                                ]
                    )
                |> Maybe.withDefault (Expect.fail "no p1 view")
