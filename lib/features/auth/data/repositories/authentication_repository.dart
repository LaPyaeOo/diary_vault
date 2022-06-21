import 'package:dairy_app/core/errors/database_exceptions.dart';
import 'package:dairy_app/core/logger/logger.dart';
import 'package:dairy_app/core/network/network_info.dart';
import 'package:dairy_app/features/auth/core/failures/failures.dart';
import 'package:dairy_app/features/auth/data/datasources/local%20data%20sources/local_data_source_template.dart';
import 'package:dairy_app/features/auth/data/datasources/remote%20data%20sources/remote_data_source_template.dart';
import 'package:dairy_app/features/auth/domain/entities/logged_in_user.dart';
import 'package:dairy_app/features/auth/domain/repositories/authentication_repository.dart';
import 'package:dartz/dartz.dart';
import 'package:firebase_auth/firebase_auth.dart';

final log = printer("AuthenticationRepository");

class AuthenticationRepository implements IAuthenticationRepository {
  final INetworkInfo networkInfo;
  final IAuthRemoteDataSource remoteDataSource;
  final IAuthLocalDataSource localDataSource;

  AuthenticationRepository(
      {required this.remoteDataSource,
      required this.localDataSource,
      required this.networkInfo});

  @override
  Future<Either<SignUpFailure, LoggedInUser>> signUpWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    log.i("signUpWithEmailAndPassword - [$email, $password]");

    if (await networkInfo.isConnected) {
      late LoggedInUser user;
      try {
        user =
            await remoteDataSource.signUpUser(email: email, password: password);
      } on FirebaseAuthException catch (e) {
        log.w("signup failed because of remote exception ${e.code}");

        switch (e.code) {
          case 'email-already-in-use':
            return Left(SignUpFailure.emailAlreadyExists());
          case 'invalid-email':
            return Left(SignUpFailure.invalidEmail());
          case 'weak-password':
            return Left(SignUpFailure.invalidPassword(
                "password must be atleast 6 characters"));
          default:
            return Left(SignUpFailure.unknownError());
        }
      }

      try {
        user = await localDataSource.signUpUser(
          id: user.id,
          email: email,
          password: password,
        );
        log.i("signup successful");

        return Right(user);
      } on DatabaseInsertionException catch (e) {
        log.e("sign up failed becuase of database exception");

        return Left(SignUpFailure.unknownError());
      }
    }
    log.w("sign up failed because of no internet");
    return Left(SignUpFailure.noInternetConnection());
  }

  /// helper method used by [signInWithEmailAndPassword] to prevent nested code
  Future<Either<SignInFailure, LoggedInUser>> _remoteLogin(
      {required String email, required String password}) async {
    late LoggedInUser user;
    log.i("signInWithEmailAndPassword - [$email, $password]");

    if (await networkInfo.isConnected) {
      try {
        user = await remoteDataSource.signInUser(
          email: email,
          password: password,
        );

        log.i("sign in successful, from remote database $user");

        try {
          await localDataSource.cacheUser(
              id: user.id, email: email, password: password);
        } on DatabaseInsertionException catch (e) {
          //! silently fail for this exception, as it is not critical

          log.e("caching of user into local db failed");
        }

        return Right(user);
      } on FirebaseAuthException catch (e) {
        log.w("sign in failed because of remote database exception ${e.code}");

        switch (e.code) {
          case 'invalid-email':
            return Left(SignInFailure.invalidEmail());
          case 'user-disabled':
            return Left(SignInFailure.userDisabled());
          case 'user-not-found':
            return Left(SignInFailure.emailDoesNotExists());
          case 'wrong-password':
            return Left(SignInFailure.wrongPassword());
          default:
            return Left(SignInFailure.unknownError());
        }
      }
    }
    log.w("sign in failed because of no internet");

    return Left(SignInFailure.noInternetConnection());
  }

  @override
  Future<Either<SignInFailure, LoggedInUser>> signInWithEmailAndPassword(
      {required String email, required String password}) async {
    late LoggedInUser user;
    try {
      user = await localDataSource.signInUser(email: email, password: password);
      log.i("sign in successful, from local database $user");

      return Right(user);
    } on SignInFailure catch (e) {
      log.e("sign in failed because of incorrect credentails $e.code");
      switch (e.code) {
        case SignInFailure.WRONG_PASSWORD:
          return _remoteLogin(email: email, password: password);
        case SignInFailure.EMAIL_DOES_NOT_EXISTS:
          return _remoteLogin(email: email, password: password);
        default:
          return Left(SignInFailure.unknownError());
      }
    } on DatabaseQueryException {
      log.e("sign in failed because of local database exception");

      return Left(SignInFailure.unknownError());
    }
  }

  @override
  Future<bool> verifyPassword(String userId, String password) async {
    try {
      return localDataSource.verifyPassword(userId, password);
    } catch (e) {
      return false;
    }
  }
}
