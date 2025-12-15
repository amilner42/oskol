module Helpers exposing
    ( ShopCardCategory(..)
    , buildGameState
    , getMaxSelection
    , isDeckBuilderCard
    , isDenialCard
    , isLevelUpCard
    , isPlusBombCard
    , isSabotageCard
    , levelUpHandType
    , shopCardCategory
    , shopCardDescription
    , shopCardId
    , shopCardName
    )

import Dict
import Types exposing (..)


{-| Shop card category type
-}
type ShopCardCategory
    = ResearchCategory
    | CounterCategory
    | LogisticsCategory
    | SabotageCategory


{-| Get the ID of a shop card
-}
shopCardId : ShopCard -> String
shopCardId card =
    card.id


{-| Get the name of a shop card
-}
shopCardName : ShopCard -> String
shopCardName card =
    case card.kind of
        Types.Research inner ->
            case inner of
                LevelUpCard handType ->
                    Types.handTypeToString handType

        Types.Counter inner ->
            case inner of
                DenialCard handType ->
                    Types.handTypeToString handType

        Types.Logistics inner ->
            case inner of
                FortifyCard _ _ ->
                    "Fortify"

                AmplifyCard _ _ ->
                    "Amplify"

                SupplyDropCard _ ->
                    "Supply Drop"

                DischargeCard _ ->
                    "Discharge"

                CamoCard suit _ ->
                    case suit of
                        Hearts ->
                            "Camo ♥"

                        Diamonds ->
                            "Camo ♦"

                        Clubs ->
                            "Camo ♣"

                        Spades ->
                            "Camo ♠"

                PromoteCard _ ->
                    "Promote"

        Types.Sabotage inner ->
            case inner of
                ScramblerCard ->
                    "Scrambler"

                PlusBombCard _ ->
                    "Napalm Strikes"

                StaticFieldCard ->
                    "Static Field"

                SupplyChainCard ->
                    "Supply Chain"


{-| Get the description of a shop card
-}
shopCardDescription : ShopCard -> String
shopCardDescription card =
    case card.kind of
        Types.Research inner ->
            case inner of
                LevelUpCard handType ->
                    "Increase " ++ Types.handTypeToString handType ++ " level by 1"

        Types.Counter inner ->
            case inner of
                DenialCard handType ->
                    "Opponent cannot score with " ++ Types.handTypeToString handType ++ " next round"

        Types.Logistics inner ->
            case inner of
                FortifyCard amount maxCards ->
                    "Enhance " ++ String.fromInt maxCards ++ " cards with +" ++ String.fromInt amount ++ " chips"

                AmplifyCard amount maxCards ->
                    "Enhance " ++ String.fromInt maxCards ++ " cards with +" ++ String.fromInt amount ++ " mult"

                SupplyDropCard maxCards ->
                    let
                        cardText =
                            if maxCards == 1 then
                                "card"

                            else
                                "cards"
                    in
                    "Add " ++ String.fromInt maxCards ++ " " ++ cardText ++ " to your deck"

                DischargeCard maxCards ->
                    let
                        cardText =
                            if maxCards == 1 then
                                "card"

                            else
                                "cards"
                    in
                    "Remove " ++ String.fromInt maxCards ++ " " ++ cardText ++ " from your deck"

                CamoCard suit maxCards ->
                    "Convert " ++ String.fromInt maxCards ++ " cards to " ++ suitToString suit

                PromoteCard maxCards ->
                    "Increase the rank of " ++ String.fromInt maxCards ++ " cards. Aces become 2s"

        Types.Sabotage inner ->
            case inner of
                ScramblerCard ->
                    "Opponent's cards will have a 1 in 5 chance of being drawn face down next round"

                PlusBombCard _ ->
                    "Disable opponent's selected cards (won't score next round)"

                StaticFieldCard ->
                    "Opponent's card enhancements will not score next round"

                SupplyChainCard ->
                    "Opponent will draw at most 4 cards after every play or discard next round"


{-| Get the category of a shop card
-}
shopCardCategory : ShopCard -> ShopCardCategory
shopCardCategory card =
    case card.kind of
        Types.Research _ ->
            ResearchCategory

        Types.Counter _ ->
            CounterCategory

        Types.Logistics _ ->
            LogisticsCategory

        Types.Sabotage _ ->
            SabotageCategory


{-| Get the maximum number of cards that can be selected for a shop card
-}
getMaxSelection : ShopCard -> Int
getMaxSelection card =
    case card.kind of
        Types.Research _ ->
            0

        Types.Counter _ ->
            0

        Types.Logistics inner ->
            case inner of
                FortifyCard _ maxCards ->
                    maxCards

                AmplifyCard _ maxCards ->
                    maxCards

                SupplyDropCard maxCards ->
                    maxCards

                DischargeCard maxCards ->
                    maxCards

                CamoCard _ maxCards ->
                    maxCards

                PromoteCard maxCards ->
                    maxCards

        Types.Sabotage inner ->
            case inner of
                ScramblerCard ->
                    0

                PlusBombCard maxCards ->
                    maxCards

                StaticFieldCard ->
                    0

                SupplyChainCard ->
                    0


{-| Check if a shop card is a level up card
-}
isLevelUpCard : ShopCard -> Bool
isLevelUpCard card =
    case card.kind of
        Types.Research (LevelUpCard _) ->
            True

        _ ->
            False


{-| Check if a shop card is a deck builder card (logistics)
-}
isDeckBuilderCard : ShopCard -> Bool
isDeckBuilderCard card =
    case card.kind of
        Types.Logistics _ ->
            True

        _ ->
            False


{-| Check if a shop card is a sabotage card
-}
isSabotageCard : ShopCard -> Bool
isSabotageCard card =
    case card.kind of
        Types.Sabotage _ ->
            True

        _ ->
            False


{-| Check if a shop card is a denial card
-}
isDenialCard : ShopCard -> Bool
isDenialCard card =
    case card.kind of
        Types.Counter (DenialCard _) ->
            True

        _ ->
            False


{-| Check if a shop card is a plus bomb card
-}
isPlusBombCard : ShopCard -> Bool
isPlusBombCard card =
    case card.kind of
        Sabotage (PlusBombCard _) ->
            True

        _ ->
            False


{-| Get the hand type from a level up card
-}
levelUpHandType : ShopCard -> Maybe HandType
levelUpHandType card =
    case card.kind of
        Types.Research (LevelUpCard handType) ->
            Just handType

        _ ->
            Nothing


{-| Helper to convert suit to string
-}
suitToString : Suit -> String
suitToString suit =
    case suit of
        Hearts ->
            "Hearts"

        Diamonds ->
            "Diamonds"

        Clubs ->
            "Clubs"

        Spades ->
            "Spades"


{-| Build fake GameState from PlayerView
This creates a minimal GameState that has enough data for the original view helpers to work
-}
buildGameState : Model -> PlayerView -> GameState
buildGameState model playerView =
    case playerView of
        PlayingView playingData ->
            let
                yourPlayerState =
                    buildYourPlayerState playingData

                opponentPlayerState =
                    buildOpponentPlayerState playingData

                playerId =
                    Maybe.withDefault "you" model.playerId
            in
            { roundNumber = playingData.roundNumber
            , playerNames =
                Dict.fromList
                    [ ( playerId, "You" )
                    , ( "opponent", playingData.opponentName )
                    ]
            , players =
                Dict.fromList
                    [ ( playerId, yourPlayerState )
                    , ( "opponent", opponentPlayerState )
                    ]
            , phase = Playing
            , gameStatus = Active
            , lastHandResults = Nothing
            , roundHandHistory = []
            , winnerId = Nothing
            , lastRoundWinnerId = Nothing
            , shopState = Nothing
            , shopRounds = 0
            , initialLives = playingData.initialLives
            , handsPerRound = playingData.handsPerRound
            , discardsPerRound = playingData.discardsPerRound
            }

        ShopView shopData ->
            -- Shop view - minimal GameState needed for shop UI
            let
                playerId =
                    Maybe.withDefault "you" model.playerId

                -- Build minimal PlayerState records with lives for shop header
                yourPlayerState =
                    { playerId = shopData.yourPlayerId
                    , lives = shopData.yourLives
                    , cardPiles = { handPile = [], drawPile = [], discardPile = [] }
                    , skillTree = shopData.yourSkillTree
                    , handsRemaining = 0
                    , discardsRemaining = 0
                    , currentRoundScore = 0
                    , lockedInHand = Nothing
                    , readyForNextRound = False
                    , status = PlayerActive
                    , activeDebuffs = []
                    , scrambled = False
                    , faceDownCardIds = []
                    , disabledRanks = []
                    , disabledSuits = []
                    , enhancementsDisabled = False
                    , supplyChainLimited = False
                    }

                opponentPlayerState =
                    { playerId = shopData.opponentPlayerId
                    , lives = shopData.opponentLives
                    , cardPiles = { handPile = [], drawPile = [], discardPile = [] }
                    , skillTree = shopData.opponentSkillTree
                    , handsRemaining = 0
                    , discardsRemaining = 0
                    , currentRoundScore = 0
                    , lockedInHand = Nothing
                    , readyForNextRound = False
                    , status = PlayerActive
                    , activeDebuffs = []
                    , scrambled = False
                    , faceDownCardIds = []
                    , disabledRanks = []
                    , disabledSuits = []
                    , enhancementsDisabled = False
                    , supplyChainLimited = False
                    }
            in
            { roundNumber = shopData.currentRound
            , playerNames =
                Dict.fromList
                    [ ( shopData.yourPlayerId, shopData.yourName )
                    , ( shopData.opponentPlayerId, shopData.opponentName )
                    ]
            , players =
                Dict.fromList
                    [ ( shopData.yourPlayerId, yourPlayerState )
                    , ( shopData.opponentPlayerId, opponentPlayerState )
                    ]
            , phase = Playing
            , gameStatus = Active
            , lastHandResults = Nothing
            , roundHandHistory = []
            , winnerId = Nothing
            , lastRoundWinnerId = Nothing
            , shopState = Just shopData.shopState
            , shopRounds = shopData.totalRounds
            , initialLives = shopData.yourLives
            , handsPerRound = 4
            , discardsPerRound = 2
            }

        GameOverView gameOverData ->
            let
                playerId =
                    Maybe.withDefault "you" model.playerId

                emptySkillTree =
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

                yourPlayerState =
                    { playerId = playerId
                    , lives = gameOverData.yourFinalLives
                    , cardPiles = { handPile = [], drawPile = [], discardPile = [] }
                    , skillTree = emptySkillTree
                    , handsRemaining = 0
                    , discardsRemaining = 0
                    , currentRoundScore = 0
                    , lockedInHand = Nothing
                    , readyForNextRound = gameOverData.yourReady
                    , status =
                        if gameOverData.yourFinalLives == 0 then
                            PlayerEliminated

                        else
                            PlayerActive
                    , activeDebuffs = []
                    , scrambled = False
                    , faceDownCardIds = []
                    , disabledRanks = []
                    , disabledSuits = []
                    , enhancementsDisabled = False
                    , supplyChainLimited = False
                    }

                opponentPlayerState =
                    { playerId = "opponent"
                    , lives = gameOverData.opponentFinalLives
                    , cardPiles = { handPile = [], drawPile = [], discardPile = [] }
                    , skillTree = emptySkillTree
                    , handsRemaining = 0
                    , discardsRemaining = 0
                    , currentRoundScore = 0
                    , lockedInHand = Nothing
                    , readyForNextRound = gameOverData.opponentReady
                    , status =
                        if gameOverData.opponentFinalLives == 0 then
                            PlayerEliminated

                        else
                            PlayerActive
                    , activeDebuffs = []
                    , scrambled = False
                    , faceDownCardIds = []
                    , disabledRanks = []
                    , disabledSuits = []
                    , enhancementsDisabled = False
                    , supplyChainLimited = False
                    }
            in
            { roundNumber = 1
            , playerNames =
                Dict.fromList
                    [ ( playerId, gameOverData.yourName )
                    , ( "opponent", gameOverData.opponentName )
                    ]
            , players =
                Dict.fromList
                    [ ( playerId, yourPlayerState )
                    , ( "opponent", opponentPlayerState )
                    ]
            , phase = Playing
            , gameStatus = GameOver
            , lastHandResults = Nothing
            , roundHandHistory = []
            , winnerId =
                if gameOverData.youWon then
                    Just playerId

                else
                    Just "opponent"
            , lastRoundWinnerId = Nothing
            , shopState = Nothing
            , shopRounds = 0
            , initialLives = gameOverData.yourFinalLives
            , handsPerRound = 4
            , discardsPerRound = 2
            }


{-| Build PlayerState record for "you" from PlayingData
-}
buildYourPlayerState : PlayingData -> PlayerState
buildYourPlayerState data =
    { playerId = "you"
    , lives = data.yourLives
    , cardPiles =
        { handPile = data.yourHand
        , drawPile = data.yourDrawPile
        , discardPile = [] -- Not tracked in PlayerView (not needed for UI)
        }
    , skillTree = data.yourSkillTree
    , handsRemaining = data.yourHandsRemaining
    , discardsRemaining = data.yourDiscardsRemaining
    , currentRoundScore = data.yourCurrentScore
    , lockedInHand = data.yourLockedInHand
    , readyForNextRound = False
    , status = PlayerActive
    , activeDebuffs = data.yourActiveDebuffs
    , scrambled = data.yourScrambled
    , faceDownCardIds = data.yourFaceDownCardIds
    , disabledRanks = data.yourDisabledRanks
    , disabledSuits = data.yourDisabledSuits
    , enhancementsDisabled = data.yourEnhancementsDisabled
    , supplyChainLimited = data.yourSupplyChainLimited
    }


{-| Build PlayerState record for opponent from PlayingData
-}
buildOpponentPlayerState : PlayingData -> PlayerState
buildOpponentPlayerState data =
    { playerId = "opponent"
    , lives = data.opponentLives
    , cardPiles =
        { handPile = data.opponentHand
        , drawPile = []
        , discardPile = []
        }
    , skillTree =
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
    , handsRemaining = data.opponentHandsRemaining
    , discardsRemaining = data.opponentDiscardsRemaining
    , currentRoundScore = data.opponentCurrentScore
    , lockedInHand = data.opponentLockedInHand
    , readyForNextRound = False
    , status = PlayerActive
    , activeDebuffs = data.opponentActiveDebuffs
    , scrambled = data.opponentScrambled
    , faceDownCardIds = data.opponentFaceDownCardIds
    , disabledRanks = data.opponentDisabledRanks
    , disabledSuits = data.opponentDisabledSuits
    , enhancementsDisabled = data.opponentEnhancementsDisabled
    , supplyChainLimited = data.opponentSupplyChainLimited
    }
