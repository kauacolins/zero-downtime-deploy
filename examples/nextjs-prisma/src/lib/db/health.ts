import { prisma } from "./db";

/** Confere se o banco responde; usado pelo health check da aplicação */
export async function isDatabaseReachable() {
  try {
    await prisma.$queryRaw`SELECT 1`;
    return true;
  } catch {
    return false;
  }
}
