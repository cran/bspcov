#' Bayesian Sparse Covariance Estimation
#'
#' Provides a Bayesian sparse and positive definite estimate of a covariance matrix via the beta-mixture shrinkage prior.
#'
#' Lee, Jo and Lee (2022) proposed the beta-mixture shrinkage prior for estimating a sparse and positive definite covariance matrix.
#' The beta-mixture shrinkage prior for \eqn{\Sigma = (\sigma_{jk})} is defined as
#' \deqn{
#'  \pi(\Sigma) = \frac{\pi^{u}(\Sigma)I(\Sigma \in C_p)}{\pi^{u}(\Sigma \in C_p)}, ~ C_p = \{\mbox{ all } p \times p \mbox{ positive definite matrices }\},
#' }
#' where \eqn{\pi^{u}(\cdot)} is the unconstrained prior given by
#' \deqn{
#' \pi^{u}(\sigma_{jk} \mid \rho_{jk}) = N\left(\sigma_{jk} \mid 0, \frac{\rho_{jk}}{1 - \rho_{jk}}\tau_1^2\right)}
#' \deqn{
#' \pi^{u}(\rho_{jk}) = Beta(\rho_{jk} \mid a, b), ~ \rho_{jk} = 1 - 1/(1 + \phi_{jk})}
#' \deqn{
#' \pi^{u}(\sigma_{jj}) = Exp(\sigma_{jj} \mid \lambda).
#' }
#' For more details, see Lee, Jo and Lee (2022).
#'
#' @param X a n \eqn{\times} p data matrix with column mean zero.
#' @param Sigma an initial guess for Sigma.
#' @param prior a list giving the prior information.
#' The list includes the following parameters (with default values in parentheses):
#' \code{a (1/2)} and \code{b (1/2)} giving the shape parameters for beta distribution,
#' \code{lambda (1)} giving the hyperparameter for the diagonal elements,
#' \code{tau1sq (10000/(n*p^4))} giving the hyperparameter for the shrinkage prior of covariance.
#' @param nsample a list giving the MCMC parameters.
#' The list includes the following integers (with default values in parentheses):
#' \code{burnin (1000)} giving the number of MCMC samples in transition period,
#' \code{nmc (1000)} giving the number of MCMC samples for analysis.
#'
#' @return \item{Sigma}{a nmc \eqn{\times} p(p+1)/2 matrix including lower triangular elements of covariance matrix.}
#' \item{Phi}{a nmc \eqn{\times} p(p+1)/2 matrix including shrinkage parameters corresponding to lower triangular elements of covariance matrix.}
#' \item{p}{dimension of covariance matrix.}
#' @author Kyoungjae Lee and Seongil Jo
#' @seealso sbmspcov
#' @keywords sparse covariance
#'
#' @references Lee, K., Jo, S., and Lee, J. (2022), "The beta-mixture shrinkage prior for sparse covariances with near-minimax posterior convergence rate",
#' \emph{Journal of Multivariate Analysis}, 192, 105067.
#'
#' @importFrom stats rnorm rgamma
#' @importFrom mvnfast rmvn
#' @importFrom GIGrvg rgig
#' @importFrom matrixcalc is.positive.definite
#' @importFrom progress progress_bar
#' @export
#' @examples
#'
#' set.seed(1)
#' n <- 20
#' p <- 5
#'
#' # generate a sparse covariance matrix:
#' True.Sigma <- matrix(0, nrow = p, ncol = p)
#' diag(True.Sigma) <- 1
#' Values <- -runif(n = p*(p-1)/2, min = 0.2, max = 0.8)
#' nonzeroIND <- which(rbinom(n=p*(p-1)/2,1,prob=1/p)==1)
#' zeroIND = (1:(p*(p-1)/2))[-nonzeroIND]
#' Values[zeroIND] <- 0
#' True.Sigma[lower.tri(True.Sigma)] <- Values
#' True.Sigma[upper.tri(True.Sigma)] <- t(True.Sigma)[upper.tri(True.Sigma)]
#' if(min(eigen(True.Sigma)$values) <= 0){
#'   delta <- -min(eigen(True.Sigma)$values) + 1.0e-5
#'   True.Sigma <- True.Sigma + delta*diag(p)
#' }
#'
#' # generate a data
#' X <- MASS::mvrnorm(n = n, mu = rep(0, p), Sigma = True.Sigma)
#'
#' # compute sparse, positive covariance estimator:
#' fout <- bspcov::bmspcov(X = X, Sigma = diag(diag(cov(X))))
#' post.est.m <- bspcov::estimate(fout)
#' sqrt(mean((post.est.m - True.Sigma)^2))
#' sqrt(mean((cov(X) - True.Sigma)^2))
#'
bmspcov <- function(X, Sigma, prior = list(), nsample = list()) {
  # Estimate a sparse covariance matrix using beta-mixture shrinkage prior

  n <- nrow(X)
  p <- ncol(X)
  stopifnot(p > 1)

  ind_noi_all <- matrix(0, p-1, p)
  for (i in 1:p) {
    if (i == 1) {
      ind_noi <- 2:p
    } else if (i==p) {
      ind_noi <- 1:(p-1)
    } else {
      ind_noi <- c(1:(i-1), (i+1):p)
    }
    ind_noi_all[,i] <- ind_noi
  }

  # prior
  privals <- list(a = 1/2, b = 1/2, lambda = 1, tau1sq = 10^4/(n*p^4))
  privals[names(prior)] <- prior
  a <- privals$a
  b <- privals$b
  lambda <- privals$lambda
  tau1sq <- privals$tau1sq

  # mcmc parameters
  mcvals <- list(burnin = 1000, nmc = 1000)
  mcvals[names(nsample)] <- nsample
  burnin <- mcvals$burnin
  nmc <- mcvals$nmc

  # fixed parameters
  S <- crossprod(X)
  lam <- 1 - n/2

  # initial values
  if(min(eigen(Sigma)$val) <= 1e-15) {
    Sigma <- Sigma + (-min(eigen(Sigma)$values) + 0.001)*diag(p)
  }
  C <- solve(Sigma)
  Phi <- matrix(1, p, p)
  Psi <- matrix(1, p, p)
  tau <- matrix(tau1sq, p, p)

  # an array for posterior samples
  Sigma_save <- matrix(0, nrow = nmc, ncol = p*(p+1)/2)
  Phi_save <- matrix(0, nrow = nmc, ncol = p*(p+1)/2)

  # blocked gibbs sampler
  nmcmc <- burnin + nmc
  elapsed.time <- system.time({
    pb <- progress::progress_bar$new(total = nmcmc)
    for (iter in 1:nmcmc) {
      pb$tick()

      for (i in 1:p) {
        ind_noi <- ind_noi_all[,i]
        tau_temp <- tau[ind_noi, i]

        C11 <- C[ind_noi, ind_noi]
        C12 <- C[ind_noi, i]
        S11 <- S[ind_noi, ind_noi]
        S12 <- S[ind_noi, i]

        invSig11 <- C11 - tcrossprod(C12)/C[i,i]
        invSig11S12 <- invSig11%*%S12

        if(n >= p){
          W1 <- invSig11 %*% S11 %*% invSig11
        }else{
          X.invSig11 <- X[,ind_noi, drop=FALSE] %*% invSig11
          W1 <- crossprod(X.invSig11) /n
        }

        # Sample gamma
        beta <- Sigma[ind_noi, i, drop = FALSE]
        chi <- drop(crossprod(beta, W1 %*% beta) - 2*crossprod(beta, invSig11S12) + S[i,i])
        psi <- lambda
        gam <- GIGrvg::rgig(n=1, lambda = lam, chi = chi, psi = psi)

        # Sample beta
        W <- W1/gam + diag(1/tau_temp) + lambda*invSig11
        W <- (W + t(W))/2
        tryCatch(
          {
            W_chol <- chol(W)
          },
          error = function(cond) {
            W <- W + (-min(eigen(W)$values) + 0.001)*diag(ncol(W))
            W_chol <<- chol(W)
          }
        )
        W_i <- chol2inv(W_chol)
        mu_i <- (W_i %*% invSig11S12)/gam
        beta <- mvnfast::rmvn(n=1, mu=mu_i, sigma=W_i)[,,drop=TRUE]

        Sigma[ind_noi, i] <- beta
        Sigma[i, ind_noi] <- beta
        Sigma[i,i] <- gam + crossprod(beta, invSig11 %*% beta)

        for(j in ind_noi) {
          chi.phi <- Sigma[j,i]^2/tau1sq
          if (chi.phi <= 1e-06) {
            chi.phi <- 1e-06
          }
          Phi[j,i] <- GIGrvg::rgig(n=1, lambda = a-1/2, chi = chi.phi, psi = 2*Psi[j,i])
          Phi[i,j] <- Phi[j,i]

          Psi[j,i] <- stats::rgamma(n=1, a+b, Phi[j,i]+1)
          Psi[i,j] <- Psi[j,i]
        }
        tau[ind_noi,i] <- Phi[ind_noi,i] * tau1sq
        tau[i,ind_noi] <- tau[ind_noi,i]

        # Below updating precision matrix according to one-column change of precision matrix
        invSig11beta <- invSig11 %*% beta

        C[ind_noi, ind_noi] <- invSig11 + tcrossprod(invSig11beta)/gam
        C12 <- -invSig11beta/gam
        C[ind_noi, i] <- C12
        C[i, ind_noi] <- t(C12)
        C[i, i] <- 1/gam
      }

      # checking positive definiteness
      if(!matrixcalc::is.positive.definite(Sigma)) {
        Sigma <- Sigma + (-min(eigen(Sigma)$values) + 0.001)*diag(p)
      }

      if (iter > burnin) {
        Sigma_save[iter-burnin,] <- Sigma[!upper.tri(Sigma)]
        Phi_save[iter-burnin,] <- Phi[!upper.tri(Phi)]
      }
    }
  })[3]

  out <- list()
  out$prior <- 'bmsp'
  out$Sigma <- Sigma_save
  out$Phi <- Phi_save
  out$p <- p
  out$mcmctime <- elapsed.time
  class(out) <- 'bspcov'
  out
}
