port module Main exposing (main)

import Browser
import Decoders exposing (..)
import Dict
import Encoders exposing (..)
import Html exposing (Html)
import Json.Decode as D
import Json.Encode as E
import Set exposing (Set)
import Types exposing (..)
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
            case metadata.amount of
                Just amount ->
                    amount

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

                cmd =
                    if shopJustCompleted then
                        sendToChannel encodeReadyForNextRound

                    else
                        Cmd.none
            in
            ( { model
                | gameState = Success gameState
                , shopUIState = newShopUIState
              }
            , cmd
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
            -- NEW: Transition from BrowsingCards to PreviewingCard
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
                                            }
                                        )
                                , previewingCardIndex = Just cardIndex
                                -- Keep for backwards compat during migration
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                -- Can only preview when browsing
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

        -- Modal actions
        OpenModal modal ->
            ( { model | viewingModal = Just modal }
            , Cmd.none
            )

        CloseModal ->
            ( { model | viewingModal = Nothing }
            , Cmd.none
            )

        NoOp ->
            ( model, Cmd.none )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    receiveFromChannel handleChannelMessage


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
