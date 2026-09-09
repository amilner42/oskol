module Api.Catalog exposing
    ( Choice
    , ClockPreset
    , Copy
    , Created
    , Format
    , Game
    , GamePage
    , Library
    , NewGame
    , Room
    , RoomSeat
    , RoomState(..)
    , Setting
    , claimSeat
    , clockPresetDecoder
    , clocksInGameOrder
    , copyFor
    , createGame
    , createdDecoder
    , encodeNewGame
    , fetchGame
    , fetchLibrary
    , fetchRoom
    , formatDecoder
    , gameDecoder
    , gamePageDecoder
    , joinRoom
    , libraryDecoder
    , lookupCode
    , offeredClocks
    , roomDecoder
    , settingChoice
    , slugDecoder
    , summarise
    )

{-| The landing pages' data: the catalogue, one game's start page, and the
calls that put a player in a seat.

Every decoder is deliberately lax about fields it does not need — the
catalogue is generated from the Gleam registry and gains keys (`config`,
`min_players`, taglines) whenever a game does. Fields this client does need
but a response may omit fall back to something sane rather than failing the
whole page.

The envelope and CSRF handling live in `Api`.

-}

import Api exposing (Error)
import Json.Decode as D exposing (Decoder)
import Json.Encode as E
import Session exposing (Session)
import Url



-- TYPES


type alias Choice =
    { id : String
    , name : String
    }


type alias Setting =
    { id : String
    , name : String
    , default : String
    , choices : List Choice
    }


type alias Format =
    { id : String
    , name : String
    , description : String
    , settings : List Setting
    }


type alias Game =
    { slug : String
    , name : String
    , description : String
    , formats : List Format
    , clocks : List String
    , defaultClock : String
    }


type alias ClockPreset =
    { id : String
    , name : String
    , description : String
    }


{-| The prose a game's page is built around; `OskolWeb.GameCopy` in the
LiveView, now served with the game.
-}
type alias Copy =
    { title : String
    , description : String
    , intro : String
    , rules : List String
    , faq : List ( String, String )
    }


type alias Library =
    { games : List Game
    , comingSoon : List Game
    }


type alias GamePage =
    { game : Game
    , formats : List Format
    , clocks : List ClockPreset
    , copy : Copy
    , guestName : Maybe String
    }


{-| What the creator picked. `format` and `name` are the contract; the
settings a format offers and the clock go with them, because a room cannot
be configured without them.
-}
type alias NewGame =
    { format : String
    , name : String
    , selections : List ( String, String )
    , clock : String
    }


{-| A seat was taken: the room's code, and the URL that opens the seat.
-}
type alias Created =
    { id : String
    , path : String
    }


{-| What a plain invite link is worth, decided by the room and not by the
visitor: a free seat, a seat whose player is away, or nothing at all.
-}
type RoomState
    = Open
    | Away
    | Full
    | Missing


type alias RoomSeat =
    { id : String
    , name : String
    }


type alias Room =
    { state : RoomState
    , inviterName : Maybe String
    , summary : Maybe String
    , disconnected : List RoomSeat
    }



-- REQUESTS


fetchLibrary : Session -> (Result Error Library -> msg) -> Cmd msg
fetchLibrary session toMsg =
    Api.get session "/papi/library" libraryDecoder toMsg


fetchGame : Session -> String -> (Result Error GamePage -> msg) -> Cmd msg
fetchGame session slug toMsg =
    Api.get session ("/papi/games/" ++ escape slug) gamePageDecoder toMsg


createGame : Session -> String -> NewGame -> (Result Error Created -> msg) -> Cmd msg
createGame session slug newGame toMsg =
    Api.post session
        ("/papi/games/" ++ escape slug)
        (encodeNewGame newGame)
        createdDecoder
        toMsg


{-| The invite link's read. It runs before anything is claimed, so a visitor
never sees a join form the table has no room for.
-}
fetchRoom : Session -> String -> String -> (Result Error Room -> msg) -> Cmd msg
fetchRoom session slug gameId toMsg =
    Api.get session (roomPath slug gameId) roomDecoder toMsg


{-| Player 2 typing a name. Joining never creates a room.
-}
joinRoom : Session -> String -> String -> String -> (Result Error Created -> msg) -> Cmd msg
joinRoom session slug gameId name toMsg =
    Api.post session
        (roomPath slug gameId)
        (E.object [ ( "name", E.string name ) ])
        createdDecoder
        toMsg


{-| Taking a seat back at a table whose player went away.
-}
claimSeat : Session -> String -> String -> String -> (Result Error Created -> msg) -> Cmd msg
claimSeat session slug gameId playerId toMsg =
    Api.post session
        (roomPath slug gameId)
        (E.object [ ( "player_id", E.string playerId ) ])
        createdDecoder
        toMsg


{-| The 6-digit code prompt: which game answers to this code.
-}
lookupCode : Session -> String -> (Result Error String -> msg) -> Cmd msg
lookupCode session code toMsg =
    Api.get session ("/papi/codes/" ++ escape code) slugDecoder toMsg


roomPath : String -> String -> String
roomPath slug gameId =
    "/papi/games/" ++ escape slug ++ "/rooms/" ++ escape gameId


escape : String -> String
escape =
    Url.percentEncode



-- ENCODERS


encodeNewGame : NewGame -> E.Value
encodeNewGame newGame =
    E.object
        [ ( "format", E.string newGame.format )
        , ( "name", E.string newGame.name )
        , ( "clock", E.string newGame.clock )
        , ( "selections"
          , E.object (List.map (Tuple.mapSecond E.string) newGame.selections)
          )
        ]



-- DECODERS


libraryDecoder : Decoder Library
libraryDecoder =
    D.map2 Library
        (optionalList "games" gameDecoder)
        (optionalList "coming_soon" gameDecoder)


gamePageDecoder : Decoder GamePage
gamePageDecoder =
    D.field "game" gameDecoder
        |> D.andThen
            (\game ->
                D.map4 (\formats clocks copy guestName -> GamePage game formats clocks copy guestName)
                    (D.oneOf
                        [ D.field "formats" (D.list formatDecoder)
                        , D.succeed game.formats
                        ]
                        |> D.map
                            (\formats ->
                                if List.isEmpty formats then
                                    game.formats

                                else
                                    formats
                            )
                    )
                    clocksDecoder
                    (copyDecoder game)
                    (D.oneOf [ D.field "guest_name" (D.nullable D.string), D.succeed Nothing ])
            )


gameDecoder : Decoder Game
gameDecoder =
    D.map6 Game
        (D.field "slug" D.string)
        (optionalString "name" "")
        (optionalString "description" "")
        (optionalList "formats" formatDecoder)
        (optionalList "clocks" D.string)
        (optionalString "default_clock" "none")


formatDecoder : Decoder Format
formatDecoder =
    D.map4 Format
        (D.field "id" D.string)
        (optionalString "name" "")
        (optionalString "description" "")
        (optionalList "settings" settingDecoder)


settingDecoder : Decoder Setting
settingDecoder =
    D.map4 Setting
        (D.field "id" D.string)
        (optionalString "name" "")
        (optionalString "default" "")
        (optionalList "choices" choiceDecoder)


choiceDecoder : Decoder Choice
choiceDecoder =
    D.map2 Choice
        (D.field "id" D.string)
        (optionalString "name" "")


clockPresetDecoder : Decoder ClockPreset
clockPresetDecoder =
    D.map3 ClockPreset
        (D.field "id" D.string)
        (optionalString "name" "")
        (optionalString "description" "")


{-| The time-control presets the response carries, in the order it sent
them. A game offers a subset of them (`Game.clocks`), and the two places
that list them disagree about the order on purpose — see `offeredClocks`
and `clocksInGameOrder`.
-}
clocksDecoder : Decoder (List ClockPreset)
clocksDecoder =
    D.oneOf
        [ D.field "clock_presets" (D.list clockPresetDecoder)
        , D.field "clocks" (D.list clockPresetDecoder)
        , D.succeed []
        ]


{-| The clock picker on the create form: the presets this game offers, in
preset order (no clock first, then the rest).
-}
offeredClocks : Game -> List ClockPreset -> List ClockPreset
offeredClocks game presets =
    List.filter (\preset -> List.member preset.id game.clocks) presets


{-| The CLOCKS panel further down the page: the same presets, in the order
the game itself lists them.
-}
clocksInGameOrder : Game -> List ClockPreset -> List ClockPreset
clocksInGameOrder game presets =
    game.clocks
        |> List.filterMap
            (\id -> List.head (List.filter (\preset -> preset.id == id) presets))


copyDecoder : Game -> Decoder Copy
copyDecoder game =
    D.oneOf
        [ D.field "copy" (rawCopyDecoder game)
        , D.at [ "game", "copy" ] (rawCopyDecoder game)
        , D.succeed (copyFor game)
        ]


rawCopyDecoder : Game -> Decoder Copy
rawCopyDecoder game =
    let
        fallback =
            copyFor game
    in
    D.map5 Copy
        (optionalString "title" fallback.title)
        (optionalString "description" fallback.description)
        (optionalString "intro" fallback.intro)
        (D.oneOf [ D.field "rules" (D.list D.string), D.succeed fallback.rules ])
        (D.oneOf [ D.field "faq" (D.list faqDecoder), D.succeed [] ])


{-| A question and its answer, as an object or as a two-element pair.
-}
faqDecoder : Decoder ( String, String )
faqDecoder =
    D.oneOf
        [ D.map2 Tuple.pair (D.field "question" D.string) (D.field "answer" D.string)
        , D.map2 Tuple.pair (D.index 0 D.string) (D.index 1 D.string)
        ]


{-| The plain copy a game with no prose of its own gets, matching what
`OskolWeb.GameCopy.for_game/1` fell back to.
-}
copyFor : Game -> Copy
copyFor game =
    { title = "Play " ++ game.name ++ " online with a friend"
    , description = game.name ++ " for two, free, no accounts. Send a link and play."
    , intro = game.description
    , rules = [ game.description ]
    , faq = []
    }


createdDecoder : Decoder Created
createdDecoder =
    D.map2 Created
        (D.field "id" D.string)
        (D.field "path" D.string)


slugDecoder : Decoder String
slugDecoder =
    D.field "slug" D.string


roomDecoder : Decoder Room
roomDecoder =
    D.map4 Room
        (D.oneOf [ D.field "state" roomStateDecoder, D.succeed Open ])
        (D.oneOf [ D.field "inviter_name" (D.nullable D.string), D.succeed Nothing ])
        (D.oneOf [ D.field "summary" (D.nullable D.string), D.succeed Nothing ])
        (optionalList "disconnected" roomSeatDecoder)


roomStateDecoder : Decoder RoomState
roomStateDecoder =
    D.string
        |> D.map
            (\state ->
                case state of
                    "full" ->
                        Full

                    "away" ->
                        Away

                    "missing" ->
                        Missing

                    _ ->
                        Open
            )


roomSeatDecoder : Decoder RoomSeat
roomSeatDecoder =
    D.oneOf
        [ D.map2 RoomSeat (D.field "id" D.string) (optionalString "name" "")
        , D.map2 RoomSeat (D.index 0 D.string) (D.index 1 D.string)
        ]


optionalString : String -> String -> Decoder String
optionalString field fallback =
    D.oneOf
        [ D.field field D.string
        , D.field field (D.null fallback)
        , D.succeed fallback
        ]


optionalList : String -> Decoder a -> Decoder (List a)
optionalList field decoder =
    D.oneOf
        [ D.field field (D.list decoder)
        , D.succeed []
        ]



-- QUERIES


{-| The choice a setting is showing: what the creator picked, or its default.
-}
settingChoice : List ( String, String ) -> Setting -> String
settingChoice selections setting =
    selections
        |> List.filter (\( id, _ ) -> id == setting.id)
        |> List.head
        |> Maybe.map Tuple.second
        |> Maybe.withDefault setting.default


{-| One line describing a setup: format, chosen settings, clock — the same
sentence `GameServerState.summary/1` builds for the server's own pages. A
setting left "off" (a twist not taken) says nothing worth a slot.
-}
summarise : Format -> List ( String, String ) -> List ClockPreset -> String -> String
summarise format selections presets clockId =
    let
        choices =
            format.settings
                |> List.filterMap
                    (\setting ->
                        let
                            chosen =
                                settingChoice selections setting
                        in
                        if chosen == "off" then
                            Nothing

                        else
                            setting.choices
                                |> List.filter (\c -> c.id == chosen)
                                |> List.head
                                |> Maybe.map .name
                    )

        clock =
            if clockId == "none" then
                []

            else
                presets
                    |> List.filter (\p -> p.id == clockId)
                    |> List.head
                    |> Maybe.map (\p -> [ p.name ++ " clock" ])
                    |> Maybe.withDefault []
    in
    String.join " · " ((format.name :: choices) ++ clock)
