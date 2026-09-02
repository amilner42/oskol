module Games.Tilt.Adapter exposing (animationFromEvents, toPlayerView)

{-| Turn a generic protocol Scene into Tilt's PlayerView so the existing Tilt
UI keeps working. This is the only place that knows Tilt's zone names and
data fields.
-}

import Decoders exposing (..)
import Json.Decode as D
import Protocol exposing (Event(..), PlayerInfo, Scene)
import Types exposing (..)


toPlayerView : String -> List String -> Scene -> Maybe PlayerView
toPlayerView playerId rematchReady scene =
    case ( Protocol.findPlayer playerId scene, Protocol.opponentOf playerId scene ) of
        ( Just me, Just them ) ->
            case scene.phase of
                "playing" ->
                    Just (PlayingView (playingData scene me them))

                "shop" ->
                    Maybe.map ShopView (shopData scene me them)

                "game_over" ->
                    Just (GameOverView (gameOverData scene rematchReady me them))

                _ ->
                    Nothing

        _ ->
            Nothing



-- PLAYING


cardsIn : String -> Scene -> List Card
cardsIn zoneId scene =
    Protocol.zoneTokens zoneId scene |> List.filterMap cardFromToken


lockedIn : Scene -> PlayerInfo -> Maybe (List Card)
lockedIn scene player =
    if Protocol.hasFlag "locked_in" player then
        Just (cardsIn ("played:" ++ player.id) scene)

    else
        Nothing


skillTree : PlayerInfo -> SkillTree
skillTree player =
    Protocol.playerData skillTreeDecoder "skill_tree" player
        |> Maybe.withDefault defaultSkillTree


defaultSkillTree : SkillTree
defaultSkillTree =
    { highCard = 1
    , pair = 1
    , twoPair = 1
    , threeOfAKind = 1
    , straight = 1
    , flush = 1
    , fullHouse = 1
    , fourOfAKind = 1
    , straightFlush = 1
    }


listData : D.Decoder a -> String -> PlayerInfo -> List a
listData decoder field player =
    Protocol.playerData (D.list decoder) field player |> Maybe.withDefault []


configInt : String -> Int -> Scene -> Int
configInt key default scene =
    Protocol.sceneData (D.field key D.int) "config" scene |> Maybe.withDefault default


playingData : Scene -> PlayerInfo -> PlayerInfo -> PlayingData
playingData scene me them =
    { yourName = me.name
    , yourHand = cardsIn ("hand:" ++ me.id) scene
    , yourDrawPile = cardsIn ("deck:" ++ me.id) scene
    , yourLives = Protocol.counter "lives" me
    , yourHandsRemaining = Protocol.counter "hands_remaining" me
    , yourDiscardsRemaining = Protocol.counter "discards_remaining" me
    , yourCurrentScore = Protocol.counter "score" me
    , yourLockedInHand = lockedIn scene me
    , yourFaceDownCardIds = listData D.string "face_down_card_ids" me
    , yourDisabledRanks = listData D.int "disabled_ranks" me
    , yourDisabledSuits = listData suitDecoder "disabled_suits" me
    , yourEnhancementsDisabled = Protocol.hasFlag "enhancements_disabled" me
    , yourActiveDebuffs = listData handTypeDecoder "active_debuffs" me
    , yourScrambled = Protocol.hasFlag "scrambled" me
    , yourSupplyChainLimited = Protocol.hasFlag "supply_chain_limited" me
    , yourSkillTree = skillTree me
    , opponentName = them.name
    , opponentHand = cardsIn ("hand:" ++ them.id) scene
    , opponentLives = Protocol.counter "lives" them
    , opponentHandsRemaining = Protocol.counter "hands_remaining" them
    , opponentDiscardsRemaining = Protocol.counter "discards_remaining" them
    , opponentCurrentScore = Protocol.counter "score" them
    , opponentLockedInHand = lockedIn scene them
    , opponentFaceDownCardIds = listData D.string "face_down_card_ids" them
    , opponentDisabledRanks = listData D.int "disabled_ranks" them
    , opponentDisabledSuits = listData suitDecoder "disabled_suits" them
    , opponentEnhancementsDisabled = Protocol.hasFlag "enhancements_disabled" them
    , opponentActiveDebuffs = listData handTypeDecoder "active_debuffs" them
    , opponentScrambled = Protocol.hasFlag "scrambled" them
    , opponentSupplyChainLimited = Protocol.hasFlag "supply_chain_limited" them
    , opponentSkillTree = skillTree them
    , roundNumber = Protocol.sceneData D.int "round_number" scene |> Maybe.withDefault 1
    , handsPerRound = configInt "hands_per_round" 4 scene
    , discardsPerRound = configInt "discards_per_round" 3 scene
    , initialLives = configInt "initial_lives" 3 scene
    , pendingAnimation = Nothing
    }



-- SHOP


shopData : Scene -> PlayerInfo -> PlayerInfo -> Maybe ShopData
shopData scene me them =
    Protocol.sceneData (shopStateDecoder scene) "shop" scene
        |> Maybe.map
            (\shopState ->
                { shopState = shopState
                , availableCards = shopState.availableCards
                , yourPlayerId = me.id
                , yourName = me.name
                , yourLives = Protocol.counter "lives" me
                , yourSkillTree = skillTree me
                , opponentPlayerId = them.id
                , opponentName = them.name
                , opponentLives = Protocol.counter "lives" them
                , opponentSkillTree = skillTree them
                , currentRound = shopState.currentRound
                , totalRounds = shopState.totalRounds
                , initialLives = configInt "initial_lives" 3 scene
                }
            )


shopStateDecoder : Scene -> D.Decoder ShopState
shopStateDecoder scene =
    let
        availableCards =
            Protocol.zoneTokens "shop" scene |> List.filterMap shopCardFromToken
    in
    D.succeed ShopState
        |> andMap (D.field "total_rounds" D.int)
        |> andMap (D.field "current_round" D.int)
        |> andMap (D.field "first_picker_id" D.string)
        |> andMap (D.field "second_picker_id" D.string)
        |> andMap (D.field "first_pick_made" D.bool)
        |> andMap (D.field "second_pick_made" D.bool)
        |> andMap (D.succeed availableCards)
        |> andMap (D.field "picked_card_ids" (D.list D.string))
        |> andMap (D.field "pending_deck_builder" (D.nullable pendingDeckBuilderDecoder))
        |> andMap (D.field "pending_plus_bomb" (D.nullable pendingPlusBombDecoder))
        |> andMap (D.field "destroy_phase_complete" D.bool)
        |> andMap (D.field "destroyer_id" (D.nullable D.string))
        |> andMap (D.field "destroys_allowed" D.int)
        |> andMap (D.field "destroyed_card_ids" (D.list D.string))


pendingDeckBuilderDecoder : D.Decoder PendingDeckBuilder
pendingDeckBuilderDecoder =
    D.map4 PendingDeckBuilder
        (D.field "player_id" D.string)
        (D.field "shop_card_id" D.string)
        (D.field "card" (D.map2 ShopCard (D.field "id" D.string) (D.field "kind" shopKindDecoder)))
        (D.field "available_cards" (D.list cardDecoder))


pendingPlusBombDecoder : D.Decoder PendingPlusBomb
pendingPlusBombDecoder =
    D.map3 PendingPlusBomb
        (D.field "player_id" D.string)
        (D.field "shop_card_id" D.string)
        (D.field "available_cards" (D.list cardDecoder))



-- GAME OVER


gameOverData : Scene -> List String -> PlayerInfo -> PlayerInfo -> GameOverData
gameOverData scene rematchReady me them =
    let
        winnerId =
            Protocol.sceneData D.string "winner_id" scene
    in
    { yourName = me.name
    , opponentName = them.name
    , winnerName =
        if winnerId == Just me.id then
            me.name

        else if winnerId == Just them.id then
            them.name

        else
            "Nobody"
    , youWon = winnerId == Just me.id
    , yourFinalLives = Protocol.counter "lives" me
    , opponentFinalLives = Protocol.counter "lives" them
    , yourReady = List.member me.id rematchReady
    , opponentReady = List.member them.id rematchReady
    }



-- ANIMATION (from the hands_resolved event)


type alias ResolvedResult =
    { playerId : String
    , cards : List Card
    , handType : String
    , score : Int
    , breakdown : ScoreBreakdown
    , level : Int
    }


resolvedResultDecoder : D.Decoder ResolvedResult
resolvedResultDecoder =
    D.map6 ResolvedResult
        (D.field "player_id" D.string)
        (D.field "cards" (D.list cardDecoder))
        (D.at [ "score", "hand_type" ] D.string)
        (D.at [ "score", "total_score" ] D.int)
        (D.field "score" scoreBreakdownDecoder)
        (D.field "level" D.int)


{-| The score reveal to play, if these events contain a hands_resolved event.
-}
animationFromEvents : String -> List Event -> Maybe HandResultAnimation
animationFromEvents playerId events =
    events
        |> List.filterMap
            (\event ->
                case event of
                    Custom "hands_resolved" payload ->
                        D.decodeValue (D.field "results" (D.list resolvedResultDecoder)) payload
                            |> Result.toMaybe
                            |> Maybe.andThen (buildAnimation playerId)

                    _ ->
                        Nothing
            )
        |> List.head


buildAnimation : String -> List ResolvedResult -> Maybe HandResultAnimation
buildAnimation playerId results =
    let
        mine =
            results |> List.filter (\r -> r.playerId == playerId) |> List.head

        theirs =
            results |> List.filter (\r -> r.playerId /= playerId) |> List.head
    in
    Maybe.map2
        (\you them ->
            { yourHand = you.cards
            , yourHandType = you.handType
            , yourScore = you.score
            , yourBreakdown = you.breakdown
            , yourHandLevel = you.level
            , opponentHand = them.cards
            , opponentHandType = them.handType
            , opponentScore = them.score
            , opponentBreakdown = them.breakdown
            , opponentHandLevel = them.level
            }
        )
        mine
        theirs
