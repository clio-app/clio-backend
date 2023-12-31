//
//  File.swift
//  
//
//  Created by Thiago Henrique on 22/09/23.
//

import Foundation
import ClioEntities

public protocol UserRepository {
    func createUser(name: String, picture: String) async throws -> User
}
