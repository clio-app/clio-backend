//
//  File.swift
//  
//
//  Created by Thiago Henrique on 27/09/23.
//

import Foundation
import Vapor
import Domain
import ClioEntities

class GameSystemController: RouteCollection {
    private(set) var connections: [SocketConnection] = [SocketConnection]()
    var sessionImages: [SessionArtefact] = [SessionArtefact]()
    
    // MARK: UseCases
    let registerUserInRoomUseCase: RegisterUserInRoomUseCase
    let startGameUseCase: StartGameUseCase
    let sendMasterArtefactsUseCase: SendMasterArtefactsUseCase
    let sendUserResponseUseCase: SendUserResponseUseCase
    let startVotingUseCase: StartVotingUseCase
    let computeVotingUseCase: ComputeVotingUseCase
    let endRoundUseCase: EndRoundUseCase
    let chooseNewMasterUseCase: ChooseMasterUseCase
    
    init(
        registerUserInRoomUseCase: RegisterUserInRoomUseCase,
        startGameUseCase: StartGameUseCase,
        sendMasterArtefactsUseCase: SendMasterArtefactsUseCase,
        sendUserResponseUseCase: SendUserResponseUseCase,
        startVotingUseCase: StartVotingUseCase,
        computeVotingUseCase: ComputeVotingUseCase,
        endRoundUseCase: EndRoundUseCase,
        chooseNewMasterUseCase: ChooseMasterUseCase
    ) {
        self.registerUserInRoomUseCase = registerUserInRoomUseCase
        self.startGameUseCase = startGameUseCase
        self.sendMasterArtefactsUseCase = sendMasterArtefactsUseCase
        self.sendUserResponseUseCase = sendUserResponseUseCase
        self.startVotingUseCase = startVotingUseCase
        self.computeVotingUseCase = computeVotingUseCase
        self.endRoundUseCase = endRoundUseCase
        self.chooseNewMasterUseCase = chooseNewMasterUseCase
    }
    
    func boot(routes: RoutesBuilder) throws {
        routes.group("game") { game in
            game.group(":roomID") { gameID in
                gameID.webSocket(onUpgrade: onSocketUpgrade)
                gameID.on(.POST, "artefacts", body: .collect(maxSize: "10mb"), use: uploadPicture)
                gameID.get("artefacts", use: getSessionPicture)
            }
        }
    }
}

// MARK: - API Callbacks
extension GameSystemController {
    func getSessionPicture(_ request: Request) async throws -> SessionArtefact {
        let imageId: UUID = try request.content.decode(UUID.self)
        guard let findedPicture = sessionImages.first(where: { $0.id == imageId }) else {
            throw Abort(.noContent)
        }
        return findedPicture
    }
    
    func uploadPicture(_ request: Request) async throws -> UploadPictureResponse {
        switch request.headers.contentType {
            case .formData?:
//                let decoder = FormDataDecoder()
                let requestData = try request.content.decode(SessionArtefact.self)
//                let requestData = try decoder.decode(
//                    SessionArtefact.self,
//                    from: request.body.data!,
//                    headers: request.headers
//                )
//                let multiPart = MultipartPart(body: requestData.picture)
//                guard let file = File(multipart: multiPart) else {
//                    throw Abort(.unsupportedMediaType)
//                }
            guard let contentType = requestData.picture?.contentType,
                        [.png, .jpeg, .mpeg].contains(contentType) else {
                            throw Abort(.unsupportedMediaType)
                        }
                sessionImages.append(requestData)
                return UploadPictureResponse(id: requestData.id!.uuidString)
            default:
                throw Abort(.badRequest)
        }
    }
    
    func onSocketUpgrade(_ request: Request, _ socket: WebSocket) {
        guard let roomId = request.parameters.get("roomID") else { return }
        
        socket.onBinary { [weak self] socket, value in
            guard let strongSelf = self else { return }
        
            if let request = try? JSONDecoder().decode(
                TransferMessage.self,
                from: value
            ) {
                switch request.state {
                    case .client(let clientMessages):
                        do {
                            try await strongSelf.handleSocketClientRequest(
                                 roomId,
                                 socket,
                                 message: request,
                                 state: clientMessages
                             )
                        } catch {
                            let message = TransferMessage(
                                state: .server(.error),
                                data: SocketError.cantHandleClientMessage(
                                    error.localizedDescription
                                )
                                .errorDescription?.data(using: .utf8) ?? Data()
                            )
                            
                            try? await socket.send(
                                raw: message.encodeToTransfer(),
                                opcode: .binary
                            )
                        }
                    case .server(_):
                        break
                }
            } else {
                let message = TransferMessage(
                    state: .server(.error),
                    data: SocketError.unableToDecodeMessage.errorDescription?.data(using: .utf8) ?? Data()
                )
                
                try? await socket.send(
                    raw: message.encodeToTransfer(),
                    opcode: .binary
                )
            }
        }
    }
    
    func sendMessageToAllConnections(_ message: TransferMessage, in room: String) {
        let messageData = message.encodeToTransfer()
        let connectionsInRoom = connections.filter( { $0.roomId == room })
        connectionsInRoom.forEach { $0.socket.send(raw: messageData, opcode: .binary) }
    }
    
    func handleSocketClientRequest(
        _ roomId: String,
        _ socket: WebSocket,
        message: TransferMessage,
        state: MessageState.ClientMessages
    ) async throws {
        switch state {
            case .gameFlow(let gameFlowMessage):
                try await handleSocketGameflowRequest(
                    roomId,
                    socket,
                    message: message,
                    state: gameFlowMessage
                )
        }
    }
    
    func handleSocketGameflowRequest(
        _ roomId: String,
        _ socket: WebSocket,
        message: TransferMessage,
        state: MessageState.ClientMessages.ClientGameFlow
    ) async throws {
        switch state {
        case .registerUser:
            let dto = RegisterUserinRoomDTO.decodeFromMessage(message.data)
            let response: UpdatePlayersRoomDTO = try await registerUserInRoomUseCase.execute(
                request: RegisterUserRequest(
                    roomCode: roomId,
                    user: dto.user
                )
            )
            connections.append(
                SocketConnection(
                    roomId: roomId,
                    userId: dto.user.id,
                    socket: socket
                )
            )
            sendMessageToAllConnections(
                TransferMessage(
                    state: .server(.connection(.playerConnected)),
                    data: response.encodeToTransfer()
                ),
                in: roomId
            )
        case .gameStarted:
            let dto = BooleanMessageDTO.decodeFromMessage(message.data)
            if !dto.value { return }
            
            let response: MasterActingDTO = try await startGameUseCase.execute(
                request: roomId
            )
            sendMessageToAllConnections(
                TransferMessage(
                    state: .server(.gameFlow(.masterActing)),
                    data: response.encodeToTransfer()
                ),
                in: roomId
            )
        case .masterChoosed:
            let dto: ChooseMasterDTO = ChooseMasterDTO.decodeFromMessage(message.data)
            let response: MasterChoosedDTO = chooseNewMasterUseCase.execute(request: dto)
            
            sendMessageToAllConnections(
                TransferMessage(
                    state: .server(.gameFlow(.chooseMaster)),
                    data: response.encodeToTransfer()
                ),
                in: roomId
            )
        case .masterActed:
            let dto = MasterActedDTO.decodeFromMessage(message.data)
            let response: MasterSharingDTO = sendMasterArtefactsUseCase.execute(request: dto)
            sendMessageToAllConnections(
                TransferMessage(
                    state: .server(.gameFlow(.masterSharing)),
                    data: response.encodeToTransfer()
                ),
                in: roomId
            )
        case .userActed:
            let dto = UserActedDTO.decodeFromMessage(message.data)
            let response: UserDidActDTO = sendUserResponseUseCase.execute(request: dto)
            sendMessageToAllConnections(
                TransferMessage(
                    state: .server(.gameFlow(.userDidAct)),
                    data: response.encodeToTransfer()
                ),
                in: roomId
            )
            if let votingDTO = startVotingUseCase.execute(request: response) {
                sendMessageToAllConnections(
                    TransferMessage(
                        state: .server(.gameFlow(.startVoting)),
                        data: votingDTO.encodeToTransfer()
                    ),
                    in: roomId
                )
            }
        case .userVoted:
            let dto = UserVotedDTO.decodeFromMessage(message.data)
            let response: UserDidVoteDTO = computeVotingUseCase.execute(request: dto)
            sendMessageToAllConnections(
                TransferMessage(
                    state: .server(.gameFlow(.userDidVote)),
                    data: response.encodeToTransfer()
                ),
                in: roomId
            )
            if let winner = endRoundUseCase.execute() {
                sendMessageToAllConnections(
                    TransferMessage(
                        state: .server(.gameFlow(.roundEnd)),
                        data: winner.encodeToTransfer()
                    ),
                    in: roomId
                )
            }
            case .playAgain:
                break
        }
    }
}
