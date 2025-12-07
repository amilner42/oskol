port module Main exposing (main)

import Browser
import Decoders exposing (..)
import Dict
import Encoders exposing (..)
import Html exposing (Html)
import Json.Decode as D
import Json.Encode as E
import Set exposing (Set)
import Task
import Time
import Types exposing (..)
import Url exposing (percentEncode)
import View.Game



-- MAIN


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }



-- PORTS


port sendToChannel : E.Value -> Cmd msg


port receiveFromChannel : (E.Value -> msg) -> Sub msg


port navigateToUrl : String -> Cmd msg



-- FLAGS


type alias Flags =
    { gameId : String
    , playerId : Maybe String
    }



-- MODEL


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( { gameId = flags.gameId
      , playerId = flags.playerId
      , gameState = Loading
      , viewingModal = Nothing
      , selectedCards = Set.empty
      , newCardIds = Set.empty
      , acknowledgedEventSeq = 0
      , connectionStatus = Connecting
      , cardSort = ByRank
      , previewingCardIndex = Nothing
      , deckBuilderSelection = []
      , plusBombSelection = Nothing
      , shopUIState = Nothing
      , rematchRequested = False
      , scoreAnimation = { phase = AnimationIdle, cardIndex = 0, nextStepTime = Nothing }
      , viewingResults = False
      }
    , Cmd.none
    )



-- SHOP STATE DERIVATION


{-| Helper to check if it's player's turn in shop
-}
isPlayerTurnInShop : ShopState -> String -> Bool
isPlayerTurnInShop shopState playerId =
    if not shopState.firstPickMade && shopState.firstPickerId == playerId then
        True

    else if shopState.firstPickMade && not shopState.secondPickMade && shopState.secondPickerId == playerId then
        True

    else
        False


{-| Derives the client-side shop UI state from the server's ShopState.
Called on every GameStateUpdated message.
-}
deriveShopUIState : String -> ShopState -> ShopUIState
deriveShopUIState playerId shopState =
    -- Priority order matters: check phases from most specific to least specific
    if not shopState.destroyPhaseComplete then
        -- DESTROY PHASE
        DestroyPhase
            { isMyTurn = shopState.destroyerId == Just playerId
            , destroysRemaining = shopState.destroysAllowed - List.length shopState.destroyedCardIndices
            , availableCards = shopState.availableCards
            , destroyedIndices = shopState.destroyedCardIndices
            }

    else if shopState.currentRound == shopState.totalRounds && shopState.firstPickMade && shopState.secondPickMade then
        -- SHOP COMPLETE
        ShopComplete
            { availableCards = shopState.availableCards
            , pickedIndices = shopState.pickedCardIndices
            , destroyedIndices = shopState.destroyedCardIndices
            }

    else
        -- PICKING PHASE - check for pending selections first
        case shopState.pendingDeckBuilder of
            Just pending ->
                if pending.playerId == playerId then
                    -- I'm in deck builder selection mode
                    SelectingDeckBuilderCards
                        { cardIndex = pending.shopCardIndex
                        , deckBuilderCard = pending.deckBuilderCard
                        , availableCards = pending.availableCards
                        , selectedCardIds = Set.empty
                        , maxSelection = getMaxSelection pending.deckBuilderCard
                        , availableShopCards = shopState.availableCards
                        , pickedIndices = shopState.pickedCardIndices
                        , destroyedIndices = shopState.destroyedCardIndices
                        }

                else
                    -- Opponent is in deck builder selection
                    WaitingForOpponent
                        { reason = OpponentPicking
                        , availableCards = shopState.availableCards
                        , pickedIndices = shopState.pickedCardIndices
                        , destroyedIndices = shopState.destroyedCardIndices
                        }

            Nothing ->
                case shopState.pendingPlusBomb of
                    Just pending ->
                        if pending.playerId == playerId then
                            -- I'm in plus bomb selection mode
                            SelectingPlusBombCard
                                { cardIndex = pending.shopCardIndex
                                , availableCards = pending.availableCards
                                , selectedCardId = Nothing
                                , availableShopCards = shopState.availableCards
                                , pickedIndices = shopState.pickedCardIndices
                                , destroyedIndices = shopState.destroyedCardIndices
                                }

                        else
                            -- Opponent is in plus bomb selection
                            WaitingForOpponent
                                { reason = OpponentPicking
                                , availableCards = shopState.availableCards
                                , pickedIndices = shopState.pickedCardIndices
                                , destroyedIndices = shopState.destroyedCardIndices
                                }

                    Nothing ->
                        -- Normal picking (no pending selections)
                        if isPlayerTurnInShop shopState playerId then
                            -- My turn to pick, browsing cards
                            BrowsingCards
                                { availableCards = shopState.availableCards
                                , pickedIndices = shopState.pickedCardIndices
                                , destroyedIndices = shopState.destroyedCardIndices
                                }

                        else
                            -- Not my turn
                            WaitingForOpponent
                                { reason = OpponentPicking
                                , availableCards = shopState.availableCards
                                , pickedIndices = shopState.pickedCardIndices
                                , destroyedIndices = shopState.destroyedCardIndices
                                }


{-| Helper to determine max selection for deck builder cards
-}
getMaxSelection : ShopCard -> Int
getMaxSelection shopCard =
    case shopCard.metadata of
        Just metadata ->
            case metadata.maxCards of
                Just maxCards ->
                    maxCards

                Nothing ->
                    1

        Nothing ->
            1


{-| Smart derivation that preserves transient UI state when in the same phase
-}
deriveShopUIStatePreservingSelections : String -> ShopState -> Maybe ShopUIState -> ShopUIState
deriveShopUIStatePreservingSelections playerId shopState previousUIState =
    let
        newState =
            deriveShopUIState playerId shopState
    in
    case ( previousUIState, newState ) of
        -- Preserve deck builder selections if still in same selection phase
        ( Just (SelectingDeckBuilderCards prev), SelectingDeckBuilderCards new ) ->
            if prev.cardIndex == new.cardIndex then
                SelectingDeckBuilderCards { new | selectedCardIds = prev.selectedCardIds }

            else
                newState

        -- Preserve plus bomb selection if still in same selection phase
        ( Just (SelectingPlusBombCard prev), SelectingPlusBombCard new ) ->
            if prev.cardIndex == new.cardIndex then
                SelectingPlusBombCard { new | selectedCardId = prev.selectedCardId }

            else
                newState

        -- For all other cases, use the new state
        _ ->
            newState


{-| Generate a deterministic rematch game ID
-}
generateRematchId : String -> String
generateRematchId currentId =
    -- Check if ID already has a rematch suffix (e.g., "abc123-r2")
    if String.contains "-r" currentId then
        -- Extract base and number, increment
        case String.split "-r" currentId of
            [base, numStr] ->
                case String.toInt numStr of
                    Just num ->
                        base ++ "-r" ++ String.fromInt (num + 1)
                    Nothing ->
                        currentId ++ "-r1"
            _ ->
                currentId ++ "-r1"
    else
        -- First rematch
        currentId ++ "-r1"



-- SCORE ANIMATION HELPERS


{-| Advance to the next animation step based on current phase and game state
-}
advanceAnimationStep : Model -> Int -> ( Model, Cmd Msg )
advanceAnimationStep model currentTime =
    case model.gameState of
        Success gameState ->
            case ( model.playerId, gameState.lastHandResults ) of
                ( Just playerId, Just handResults ) ->
                    let
                        -- Get both player results
                        playerNames =
                            Dict.toList gameState.playerNames
                                |> List.sortBy Tuple.second
                                |> List.map Tuple.first

                        -- Determine alphabetical order (first player = opponent in animation phases)
                        ( firstPlayerId, secondPlayerId ) =
                            case playerNames of
                                [ p1, p2 ] ->
                                    ( p1, p2 )

                                _ ->
                                    ( "", "" )

                        firstResult =
                            Dict.get firstPlayerId handResults

                        secondResult =
                            Dict.get secondPlayerId handResults

                        firstCardCount =
                            firstResult
                                |> Maybe.map (.scoreBreakdown >> .cardBreakdowns >> List.length)
                                |> Maybe.withDefault 0

                        secondCardCount =
                            secondResult
                                |> Maybe.map (.scoreBreakdown >> .cardBreakdowns >> List.length)
                                |> Maybe.withDefault 0

                        ( nextPhase, nextIndex, delayMs ) =
                            nextAnimationStep
                                model.scoreAnimation.phase
                                model.scoreAnimation.cardIndex
                                firstCardCount
                                secondCardCount

                        newAnimation =
                            { phase = nextPhase
                            , cardIndex = nextIndex
                            , nextStepTime =
                                if nextPhase == AnimationComplete then
                                    Nothing

                                else
                                    Just (currentTime + delayMs)
                            }

                        -- Auto-dismiss when animation completes
                        shouldDismiss =
                            nextPhase == AnimationComplete
                    in
                    ( { model
                        | scoreAnimation = newAnimation
                        , viewingResults = not shouldDismiss
                      }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


{-| Animation state machine - determines next phase, card index, and delay
Matches the LiveView logic
-}
nextAnimationStep : ScoreAnimationPhase -> Int -> Int -> Int -> ( ScoreAnimationPhase, Int, Int )
nextAnimationStep currentPhase currentIndex firstCardCount secondCardCount =
    case currentPhase of
        AnimationIdle ->
            ( OpponentBase, 0, 0 )

        OpponentBase ->
            if firstCardCount > 0 then
                ( OpponentCards, 0, 600 )

            else
                ( OpponentFinal, 0, 750 )

        OpponentCards ->
            if currentIndex + 1 < firstCardCount then
                ( OpponentCards, currentIndex + 1, 600 )

            else
                ( OpponentFinal, 0, 750 )

        OpponentFinal ->
            if secondCardCount > 0 then
                ( PlayerBase, 0, 750 )

            else
                ( PlayerFinal, 0, 750 )

        PlayerBase ->
            if secondCardCount > 0 then
                ( PlayerCards, 0, 600 )

            else
                ( PlayerFinal, 0, 750 )

        PlayerCards ->
            if currentIndex + 1 < secondCardCount then
                ( PlayerCards, currentIndex + 1, 600 )

            else
                ( PlayerFinal, 0, 750 )

        PlayerFinal ->
            ( AnimationComplete, 0, 2000 )

        AnimationComplete ->
            ( AnimationComplete, 0, 0 )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ReceivedGameState gameState ->
            -- Initial game state received when joining channel
            ( { model
                | gameState = Success gameState
                , connectionStatus = Connected
              }
            , Cmd.none
            )

        GameStateUpdated gameState ->
            -- Game state update from server broadcast
            let
                -- Derive new shop UI state
                newShopUIState =
                    case ( gameState.phase, gameState.shopState, model.playerId ) of
                        ( RoundEnd, Just shopState, Just playerId ) ->
                            Just
                                (deriveShopUIStatePreservingSelections
                                    playerId
                                    shopState
                                    model.shopUIState
                                )

                        _ ->
                            Nothing

                -- Clean detection: shop just transitioned to complete
                shopJustCompleted =
                    case ( model.shopUIState, newShopUIState ) of
                        ( Just (ShopComplete _), _ ) ->
                            False

                        -- Already complete
                        ( _, Just (ShopComplete _) ) ->
                            True

                        -- Just became complete
                        _ ->
                            False

                -- Detect new hand results and start animation
                handResultsJustArrived =
                    case ( model.gameState, gameState.lastHandResults ) of
                        ( Success oldGameState, Just newResults ) ->
                            oldGameState.lastHandResults /= Just newResults

                        ( _, Just _ ) ->
                            True

                        _ ->
                            False

                ( newScoreAnimation, newViewingResults ) =
                    if handResultsJustArrived then
                        ( { phase = OpponentBase, cardIndex = 0, nextStepTime = Nothing }
                        , True
                        )

                    else
                        ( model.scoreAnimation, model.viewingResults )

                cmd =
                    if shopJustCompleted then
                        sendToChannel encodeReadyForNextRound

                    else
                        Cmd.none
            in
            ( { model
                | gameState = Success gameState
                , shopUIState = newShopUIState
                , scoreAnimation = newScoreAnimation
                , viewingResults = newViewingResults
              }
            , cmd
            )

        RematchGameReady rematchGameId ->
            -- Server has created rematch game, navigate to it with player name
            let
                playerName =
                    case ( model.playerId, model.gameState ) of
                        ( Just playerId, Success gameState ) ->
                            Dict.get playerId gameState.playerNames

                        _ ->
                            Nothing

                url =
                    case playerName of
                        Just name ->
                            "/" ++ rematchGameId ++ "?name=" ++ percentEncode name

                        Nothing ->
                            "/" ++ rematchGameId
            in
            ( model
            , navigateToUrl url
            )

        ChannelError err ->
            ( { model | gameState = Failure err }
            , Cmd.none
            )

        ConnectionStatusChanged status ->
            ( { model | connectionStatus = status }
            , Cmd.none
            )

        -- Card selection
        ToggleCardSelection cardId ->
            let
                newSelectedCards =
                    if Set.member cardId model.selectedCards then
                        Set.remove cardId model.selectedCards

                    else if Set.size model.selectedCards < 5 then
                        Set.insert cardId model.selectedCards

                    else
                        -- Already have 5 cards selected, don't add more
                        model.selectedCards
            in
            ( { model | selectedCards = newSelectedCards }
            , Cmd.none
            )

        ToggleCardSort ->
            let
                newSort =
                    case model.cardSort of
                        ByRank ->
                            BySuit

                        BySuit ->
                            ByRank
            in
            ( { model | cardSort = newSort }
            , Cmd.none
            )

        -- Game actions
        LockInHand ->
            case model.gameState of
                Success gameState ->
                    case getCurrentPlayer model of
                        Just currentPlayer ->
                            let
                                selectedCardsList =
                                    currentPlayer.cardPiles.handPile
                                        |> List.filter (\card -> Set.member card.id model.selectedCards)
                            in
                            ( { model
                                | selectedCards = Set.empty
                                , newCardIds = Set.empty
                              }
                            , sendToChannel (encodeLockInHand selectedCardsList)
                            )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        DiscardCards cardIds ->
            case model.gameState of
                Success gameState ->
                    case getCurrentPlayer model of
                        Just currentPlayer ->
                            let
                                cardsToDiscard =
                                    currentPlayer.cardPiles.handPile
                                        |> List.filter (\card -> List.member card.id cardIds)
                            in
                            ( { model
                                | selectedCards = Set.empty
                                , newCardIds = Set.empty
                              }
                            , sendToChannel (encodeDiscardCards cardsToDiscard)
                            )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        MakeShopPick cardIndex ->
            ( model
            , sendToChannel (encodeMakeShopPick cardIndex)
            )

        PreviewShopCard cardIndex ->
            -- NEW: Transition from BrowsingCards, DestroyPhase, or PreviewingCard to PreviewingCard
            case model.shopUIState of
                Just (BrowsingCards data) ->
                    case List.drop cardIndex data.availableCards |> List.head of
                        Just card ->
                            ( { model
                                | shopUIState =
                                    Just
                                        (PreviewingCard
                                            { cardIndex = cardIndex
                                            , card = card
                                            , availableCards = data.availableCards
                                            , pickedIndices = data.pickedIndices
                                            , destroyedIndices = data.destroyedIndices
                                            , isDestroyMode = False
                                            }
                                        )
                                , previewingCardIndex = Just cardIndex

                                -- Keep for backwards compat during migration
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Just (DestroyPhase data) ->
                    case List.drop cardIndex data.availableCards |> List.head of
                        Just card ->
                            ( { model
                                | shopUIState =
                                    Just
                                        (PreviewingCard
                                            { cardIndex = cardIndex
                                            , card = card
                                            , availableCards = data.availableCards
                                            , pickedIndices = []
                                            , destroyedIndices = data.destroyedIndices
                                            , isDestroyMode = True
                                            }
                                        )
                                , previewingCardIndex = Just cardIndex
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Just (PreviewingCard data) ->
                    -- Allow switching between previewed cards
                    case List.drop cardIndex data.availableCards |> List.head of
                        Just card ->
                            ( { model
                                | shopUIState =
                                    Just
                                        (PreviewingCard
                                            { cardIndex = cardIndex
                                            , card = card
                                            , availableCards = data.availableCards
                                            , pickedIndices = data.pickedIndices
                                            , destroyedIndices = data.destroyedIndices
                                            , isDestroyMode = data.isDestroyMode
                                            }
                                        )
                                , previewingCardIndex = Just cardIndex
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                -- Can only preview when browsing, destroying, or already previewing
                _ ->
                    ( model, Cmd.none )

        ClearCardPreview ->
            -- NEW: Go back to browsing
            case model.shopUIState of
                Just (PreviewingCard data) ->
                    ( { model
                        | shopUIState =
                            Just
                                (BrowsingCards
                                    { availableCards = data.availableCards
                                    , pickedIndices = data.pickedIndices
                                    , destroyedIndices = data.destroyedIndices
                                    }
                                )
                        , previewingCardIndex = Nothing
                      }
                    , Cmd.none
                    )

                _ ->
                    ( { model | previewingCardIndex = Nothing }, Cmd.none )

        ConfirmDeckBuilder cardIndex ->
            -- Send to server, which will set pendingDeckBuilder
            -- Next GameStateUpdated will transition us to SelectingDeckBuilderCards
            ( model
            , sendToChannel (encodeConfirmDeckBuilder cardIndex)
            )

        ConfirmPlusBomb cardIndex ->
            -- Send to server, which will set pendingPlusBomb
            ( model
            , sendToChannel (encodeConfirmPlusBomb cardIndex)
            )

        ToggleDeckCardSelection cardId ->
            -- NEW: Toggle selection in deck builder mode
            case model.shopUIState of
                Just (SelectingDeckBuilderCards data) ->
                    let
                        newSelected =
                            if Set.member cardId data.selectedCardIds then
                                Set.remove cardId data.selectedCardIds

                            else if Set.size data.selectedCardIds < data.maxSelection then
                                Set.insert cardId data.selectedCardIds

                            else
                                data.selectedCardIds

                        newState =
                            SelectingDeckBuilderCards { data | selectedCardIds = newSelected }
                    in
                    ( { model | shopUIState = Just newState }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SelectPlusBombCard cardId ->
            -- Update selection in plus bomb mode
            case model.shopUIState of
                Just (SelectingPlusBombCard data) ->
                    let
                        newState =
                            SelectingPlusBombCard { data | selectedCardId = Just cardId }
                    in
                    ( { model
                        | shopUIState = Just newState
                        , plusBombSelection = Just cardId
                      }
                    , Cmd.none
                    )

                _ ->
                    ( { model | plusBombSelection = Just cardId }, Cmd.none )

        ConfirmSelection ->
            -- NEW: Unified confirmation for deck builder and plus bomb
            case model.shopUIState of
                Just (SelectingDeckBuilderCards data) ->
                    let
                        selectedList =
                            Set.toList data.selectedCardIds

                        cmd =
                            if List.isEmpty selectedList then
                                sendToChannel encodeSkipDeckBuilderSelection

                            else
                                sendToChannel (encodeCompleteDeckBuilderSelection selectedList)
                    in
                    ( model, cmd )

                Just (SelectingPlusBombCard data) ->
                    case data.selectedCardId of
                        Just cardId ->
                            ( model, sendToChannel (encodeCompletePlusBombSelection cardId) )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        CancelSelection ->
            -- NEW: Cancel/skip selection
            case model.shopUIState of
                Just (SelectingDeckBuilderCards _) ->
                    ( model, sendToChannel encodeSkipDeckBuilderSelection )

                _ ->
                    ( model, Cmd.none )

        -- OLD HANDLERS (kept for backwards compatibility during migration)
        PreviewDeckBuilder cardIndex ->
            ( model
            , sendToChannel (encodeConfirmDeckBuilder cardIndex)
            )

        SelectDeckCard cardId ->
            ( { model
                | deckBuilderSelection =
                    if List.member cardId model.deckBuilderSelection then
                        List.filter (\id -> id /= cardId) model.deckBuilderSelection

                    else
                        model.deckBuilderSelection ++ [ cardId ]
              }
            , Cmd.none
            )

        CompleteDeckBuilderSelection cardIds ->
            ( { model | deckBuilderSelection = [] }
            , sendToChannel (encodeCompleteDeckBuilderSelection cardIds)
            )

        SkipDeckBuilderSelection ->
            ( { model | deckBuilderSelection = [] }
            , sendToChannel encodeSkipDeckBuilderSelection
            )

        PreviewPlusBomb cardIndex ->
            ( model
            , sendToChannel (encodeConfirmPlusBomb cardIndex)
            )

        CompletePlusBombSelection cardId ->
            ( { model | plusBombSelection = Nothing }
            , sendToChannel (encodeCompletePlusBombSelection cardId)
            )

        DestroyShopCard cardIndex ->
            ( model
            , sendToChannel (encodeDestroyShopCard cardIndex)
            )

        CompleteDestroyPhase ->
            ( model
            , sendToChannel encodeCompleteDestroyPhase
            )

        ReadyForNextRound ->
            ( model
            , sendToChannel encodeReadyForNextRound
            )

        RequestRematch ->
            ( { model | rematchRequested = True }
            , sendToChannel encodeRequestRematch
            )

        -- Modal actions
        OpenModal modal ->
            ( { model | viewingModal = Just modal }
            , Cmd.none
            )

        CloseModal ->
            ( { model | viewingModal = Nothing }
            , Cmd.none
            )

        AdvanceScoreAnimation currentTime ->
            -- Check if it's time to advance animation
            case model.scoreAnimation.nextStepTime of
                Just nextTime ->
                    if currentTime >= nextTime then
                        advanceAnimationStep model currentTime

                    else
                        ( model, Cmd.none )

                Nothing ->
                    -- First step, start immediately
                    advanceAnimationStep model currentTime

        DismissResults ->
            ( { model
                | viewingResults = False
                , scoreAnimation = { phase = AnimationIdle, cardIndex = 0, nextStepTime = Nothing }
              }
            , Cmd.none
            )

        NoOp ->
            ( model, Cmd.none )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ receiveFromChannel handleChannelMessage
        , if model.scoreAnimation.phase /= AnimationIdle && model.scoreAnimation.phase /= AnimationComplete then
            Time.every 100 (\posix -> AdvanceScoreAnimation (Time.posixToMillis posix))

          else
            Sub.none
        ]


{-| Handle messages from the Phoenix channel
-}
handleChannelMessage : E.Value -> Msg
handleChannelMessage value =
    case D.decodeValue channelMessageDecoder value of
        Ok channelMsg ->
            case channelMsg of
                InitialGameState gameState ->
                    ReceivedGameState gameState

                GameUpdate gameState ->
                    GameStateUpdated gameState

                StatusUpdate status ->
                    ConnectionStatusChanged status

                RematchReady gameId ->
                    RematchGameReady gameId

                Error err ->
                    ChannelError err

        Err err ->
            ChannelError (D.errorToString err)


{-| Decoder for channel messages
-}
type ChannelMessage
    = InitialGameState GameState
    | GameUpdate GameState
    | StatusUpdate ConnectionStatus
    | RematchReady String
    | Error String


channelMessageDecoder : D.Decoder ChannelMessage
channelMessageDecoder =
    D.field "type" D.string
        |> D.andThen
            (\msgType ->
                case msgType of
                    "initial_state" ->
                        D.map InitialGameState (D.field "game_state" gameStateDecoder)

                    "game_state_updated" ->
                        D.map GameUpdate (D.field "game_state" gameStateDecoder)

                    "connection_status" ->
                        D.map StatusUpdate (D.field "status" connectionStatusDecoder)

                    "rematch_ready" ->
                        D.map RematchReady (D.field "game_id" D.string)

                    "error" ->
                        D.map Error (D.field "message" D.string)

                    _ ->
                        D.fail ("Unknown message type: " ++ msgType)
            )


connectionStatusDecoder : D.Decoder ConnectionStatus
connectionStatusDecoder =
    D.string
        |> D.andThen
            (\str ->
                case str of
                    "disconnected" ->
                        D.succeed Disconnected

                    "connecting" ->
                        D.succeed Connecting

                    "connected" ->
                        D.succeed Connected

                    _ ->
                        D.fail ("Unknown connection status: " ++ str)
            )



-- VIEW


view : Model -> Html Msg
view model =
    View.Game.viewGame model
