//
//  File.swift
//  
//
//  Created by Thiago Henrique on 05/10/23.
//

import Foundation
import ClioEntities

public final class SendMasterArtefactsUseCase: AnyUseCase {
    let session: GameSession
    
    public init(session: GameSession) {
        self.session = session
    }
    
    public func execute(request: MasterActedDTO) -> MasterSharingDTO {
        return MasterSharingDTO(
            countdownTimer: session.getTimerForMasterData(
                pictureID: request.pictureID,
                description: request.description
            ),
            pictureID: request.pictureID
        )
    }
}
