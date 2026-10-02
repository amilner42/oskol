module SaveToSetTest exposing (suite)

{-| The save sheet (`Ui.SaveToSet`), the one both the analysis board and a
puzzle's reveal open: the account's sets from the wire, each a row with a
check; a tap inks the check at once and the answer keeps it (or puts it
back and says why); CREATE makes a set and puts the position in it; the
one line's words; a guest's sign-in, which comes back to the page it was
opened on.
-}

import Api
import Api.Decks as Decks
import Expect
import Html.Attributes
import Json.Decode as D exposing (Decoder)
import Json.Encode as E
import Session
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, id, tag, text)
import Ui.Decks as Words
import Ui.SaveToSet as Save exposing (Msg(..), Out(..))
import Ui.SignIn as SignIn


suite : Test
suite =
    describe "the save sheet"
        [ rows
        , ticking
        , creating
        , aGuest
        , words
        ]


arie : Session.Session
arie =
    Session.withUser (Just { email = "arie@example.com", name = Just "arie" }) Session.empty


mineJson : String
mineJson =
    """{"ok":true,"decks":[{"holds":true,"id":"K7M2Q9XA","name":"Openings I like","size":12,"new_per_day":5,"standing":null},{"holds":false,"id":"Z3W8R1PB","name":"Back games","size":0,"new_per_day":5,"standing":null}]}"""


setJson : String -> String -> Int -> String
setJson setId name size =
    "{\"ok\":true,\"deck\":{\"id\":\""
        ++ setId
        ++ "\",\"name\":\""
        ++ name
        ++ "\",\"size\":"
        ++ String.fromInt size
        ++ ",\"new_per_day\":5,\"standing\":null},\"added\":true}"


refusal : String -> String -> Result Api.Error a
refusal code message =
    Err (Api.ApiError { code = code, message = message })


opened : Session.Session -> Save.Model
opened session =
    Save.init session { puzzleId = "pz000001", next = "/analysis?xgid=XGID%3D-b" } |> Tuple.first


loaded : Save.Model
loaded =
    opened arie |> send (GotSets (Api.parseBody Decks.mineDecoder mineJson))


send : Msg -> Save.Model -> Save.Model
send msg model =
    Save.update arie msg model |> (\( next, _, _ ) -> next)


out : Msg -> Save.Model -> Out
out msg model =
    Save.update arie msg model |> (\( _, _, o ) -> o)


rendered : Save.Model -> Query.Single Msg
rendered model =
    Save.view model |> Query.fromHtml


checked : String -> String -> Query.Single Msg -> Expect.Expectation
checked setId value =
    Query.find [ id ("save-set-" ++ setId) ] >> Query.has [ attribute (Html.Attributes.attribute "aria-checked" value) ]


rows : Test
rows =
    describe "the sets"
        [ test "one row per set, in the wire's order, each with its name and size" <|
            \_ ->
                rendered loaded
                    |> Query.find [ id "save-sets" ]
                    |> Query.children []
                    |> Expect.all
                        [ Query.count (Expect.equal 2)
                        , Query.index 0 >> Query.has [ id "save-set-K7M2Q9XA", text "Openings I like", text "12 positions" ]
                        , Query.index 1 >> Query.has [ id "save-set-Z3W8R1PB", text "Back games", text "0 positions" ]
                        ]
        , test "a set that holds this position already is checked; one that does not is not" <|
            \_ ->
                rendered loaded
                    |> Expect.all [ checked "K7M2Q9XA" "true", checked "Z3W8R1PB" "false" ]
        , test "no sets yet says what CREATE will do" <|
            \_ ->
                opened arie
                    |> send (GotSets (Ok []))
                    |> rendered
                    |> Query.find [ id "save-empty" ]
                    |> Query.has [ text "No sets yet." ]
        , test "the heading is the sheet's own, and the x closes it" <|
            \_ ->
                Expect.all
                    [ \_ -> rendered loaded |> Query.has [ id "save-modal", text "SAVE TO A SET" ]
                    , \_ -> rendered loaded |> Query.find [ id "save-close" ] |> Event.simulate Event.click |> Event.expect PressedClose
                    , \_ -> out PressedClose loaded |> Expect.equal Close
                    ]
                    ()
        ]


ticking : Test
ticking =
    describe "a tap"
        [ test "a row is a checkbox that sends its own tap" <|
            \_ ->
                rendered loaded
                    |> Query.find [ id "save-set-Z3W8R1PB" ]
                    |> Expect.all
                        [ Query.has [ tag "button", attribute (Html.Attributes.attribute "role" "checkbox") ]
                        , Event.simulate Event.click >> Event.expect (Toggled "Z3W8R1PB")
                        ]
        , test "the check inks at once, before the answer" <|
            \_ ->
                loaded
                    |> send (Toggled "Z3W8R1PB")
                    |> rendered
                    |> Expect.all
                        [ checked "Z3W8R1PB" "true"
                        , Query.find [ id "save-set-Z3W8R1PB" ] >> Query.has [ class "is-on" ]
                        ]
        , test "the answer keeps it, with the set's new size and the line" <|
            \_ ->
                loaded
                    |> send (Toggled "Z3W8R1PB")
                    |> send (GotSaved "Z3W8R1PB" (Api.parseBody (Decks.ownSetDecoder |> fieldDeck) (setJson "Z3W8R1PB" "Back games" 1)))
                    |> rendered
                    |> Expect.all
                        [ checked "Z3W8R1PB" "true"
                        , Query.find [ id "save-set-Z3W8R1PB" ] >> Query.has [ text "1 position" ]
                        , Query.find [ id "save-line" ] >> Query.has [ text "Saved to Back games · 1 position" ]
                        ]
        , test "a refusal puts the check back and says why" <|
            \_ ->
                loaded
                    |> send (Toggled "Z3W8R1PB")
                    |> send (GotSaved "Z3W8R1PB" (refusal "not_found" "There is no such set of puzzles."))
                    |> rendered
                    |> Expect.all
                        [ checked "Z3W8R1PB" "false"
                        , Query.find [ id "save-line" ] >> Query.has [ class "is-refused", text "There is no such set of puzzles." ]
                        ]
        , test "a checked row unchecks at once and the answer says where it came out of" <|
            \_ ->
                loaded
                    |> send (Toggled "K7M2Q9XA")
                    |> Expect.all
                        [ rendered >> checked "K7M2Q9XA" "false"
                        , send (GotRemoved "K7M2Q9XA" (Api.parseBody (Decks.ownSetDecoder |> fieldDeck) (setJson "K7M2Q9XA" "Openings I like" 11)))
                            >> rendered
                            >> Query.find [ id "save-line" ]
                            >> Query.has [ text "Taken out of Openings I like · 11 positions" ]
                        ]
        , test "a second tap while the first is on its way does nothing" <|
            \_ ->
                loaded
                    |> send (Toggled "Z3W8R1PB")
                    |> send (Toggled "Z3W8R1PB")
                    |> rendered
                    |> checked "Z3W8R1PB" "true"
        ]


fieldDeck : Decoder a -> Decoder a
fieldDeck =
    D.field "deck"


creating : Test
creating =
    describe "New set"
        [ test "a name field and CREATE, in a form" <|
            \_ ->
                rendered loaded
                    |> Query.find [ id "save-new" ]
                    |> Expect.all
                        [ Query.has [ tag "form" ]
                        , Query.find [ id "save-new-name" ] >> Event.simulate (Event.input "Primes") >> Event.expect (NameChanged "Primes")
                        , Query.find [ id "save-create" ] >> Query.has [ text "CREATE" ]
                        , Event.simulate (Event.custom "submit" (E.object [])) >> Event.expect SubmittedNew
                        ]
        , test "CREATE makes the set, ticked at the end of the list, and puts the position in it" <|
            \_ ->
                let
                    made =
                        loaded
                            |> send (NameChanged "Primes")
                            |> send SubmittedNew
                            |> send (GotCreated (Api.parseBody (Decks.ownSetDecoder |> fieldDeck) (setJson "P4R7M1QZ" "Primes" 0)))
                in
                Expect.all
                    [ \m ->
                        rendered m
                            |> Query.find [ id "save-sets" ]
                            |> Query.children []
                            |> Query.index 2
                            |> Query.has [ id "save-set-P4R7M1QZ", attribute (Html.Attributes.attribute "aria-checked" "true") ]
                    , \m -> rendered m |> Query.find [ id "save-new-name" ] |> Query.has [ attribute (Html.Attributes.value "") ]
                    , \m ->
                        send (GotSaved "P4R7M1QZ" (Api.parseBody (Decks.ownSetDecoder |> fieldDeck) (setJson "P4R7M1QZ" "Primes" 1))) m
                            |> rendered
                            |> Query.find [ id "save-line" ]
                            |> Query.has [ text "Saved to Primes · 1 position" ]
                    ]
                    made
        , test "a name the server refuses is said in the line, in its words" <|
            \_ ->
                loaded
                    |> send (NameChanged "openings i like")
                    |> send SubmittedNew
                    |> send (GotCreated (refusal "name_taken" "You already have a set called that"))
                    |> rendered
                    |> Query.find [ id "save-line" ]
                    |> Query.has [ class "is-refused", text "You already have a set called that" ]
        ]


aGuest : Test
aGuest =
    describe "a guest"
        [ test "is asked to sign in, and nothing else" <|
            \_ ->
                rendered (opened Session.empty)
                    |> Expect.all
                        [ Query.find [ id "save-signin-line" ] >> Query.has [ text "Sign in to keep this position." ]
                        , Query.has [ id "signin" ]
                        , Query.findAll [ id "save-sets" ] >> Query.count (Expect.equal 0)
                        ]
        , test "the sign-in comes back to the page it was opened on" <|
            \_ ->
                (opened Session.empty).signIn
                    |> Maybe.map .next
                    |> Expect.equal (Just "/analysis?xgid=XGID%3D-b")
        , test "signed in there and then, the shell is told" <|
            \_ ->
                let
                    signed =
                        { user = Just { email = "arie@example.com", name = Nothing }, saved = 0, next = "/analysis", new = False }
                in
                opened Session.empty
                    |> out (SignInMsg (SignIn.GotCode (Ok signed)))
                    |> Expect.equal (SignedIn signed.user)
        ]


words : Test
words =
    describe "the words"
        [ test "the saved line" <|
            \_ ->
                Words.savedLine { name = "Openings I like", size = 12 }
                    |> Expect.equal "Saved to Openings I like · 12 positions"
        , test "one position is one" <|
            \_ ->
                Words.savedLine { name = "Primes", size = 1 }
                    |> Expect.equal "Saved to Primes · 1 position"
        ]
