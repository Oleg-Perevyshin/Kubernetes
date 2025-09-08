#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 7-HA-ArgoCD.sh;

# Конфигурация кластера
declare -A NODES=([s1]="192.168.5.31" [vip]="192.168.5.40")
CLUSTER_SSH_KEY="/root/.ssh/id_rsa_cluster"
ARGOCD_HOST="argocd.poe-gw.keenetic.pro"
ARGOCD_PORT=30200
ARGOCD_PASSWORD="!MCMega2005!"
set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

#############################################
echo -e "${GREEN}ЭТАП 7: Установка ArgoCD${NC}"
# ----------------------------------------------------------------------------------------------- #
ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$CLUSTER_SSH_KEY" "root@${NODES[s1]}" bash <<EOF
  set -euo pipefail
  export PATH=\$PATH:/usr/local/bin

  echo -e "${GREEN}  Удаляем предыдущую установку ArgoCD${NC}"
  kubectl delete svc argocd-loadbalancer -n argocd &>/dev/null || true
  kubectl delete -n argocd-system -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml &>/dev/null || true

  echo -e "${GREEN}  Устанавливаем ArgoCD${NC}"
  kubectl create namespace argocd-system &>/dev/null || true
  kubectl apply -n argocd-system -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml &>/dev/null || true

  echo -e "${GREEN}  Назначаем права доступа для контроллера${NC}"
  kubectl apply -f - <<RBAC >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-controller-access
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: argocd-application-controller
  namespace: argocd-system
RBAC

  echo -e "${GREEN}  Ожидаем готовности контроллера${NC}"
  until kubectl -n argocd-system get statefulset argocd-application-controller &>/dev/null; do sleep 5; done
  kubectl -n argocd-system rollout restart statefulset argocd-application-controller >/dev/null
  kubectl -n argocd-system rollout status statefulset/argocd-application-controller --timeout=10m >/dev/null
  kubectl -n argocd-system wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller --timeout=2m >/dev/null

  echo -e "${GREEN}  Создаём LoadBalancer Service для ArgoCD${NC}"
  kubectl apply -f - <<SVC >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: argocd-loadbalancer
  namespace: argocd-system
  annotations:
    service.beta.kubernetes.io/kube-vip-loadbalancer-ip: "${NODES[vip]}"
spec:
  type: LoadBalancer
  loadBalancerIP: "${NODES[vip]}"
  ports:
  - name: http
    port: ${ARGOCD_PORT}
    targetPort: 8080
    protocol: TCP
  selector:
    app.kubernetes.io/name: argocd-server
SVC

  echo -e "${GREEN}  Отключаем TLS и перезапускаем сервер${NC}"
  kubectl patch configmap argocd-cmd-params-cm -n argocd-system --type merge -p '{"data":{"server.insecure": "true"}}' >/dev/null
  kubectl -n argocd-system rollout restart deployment argocd-server >/dev/null
  kubectl -n argocd-system rollout status deployment/argocd-server --timeout=10m >/dev/null
  kubectl -n argocd-system wait --for=condition=available deployment/argocd-server --timeout=1m >/dev/null

  INIT_PASS=\$(kubectl -n argocd-system get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  echo -e "${GREEN}  Логин: admin | Начальный пароль: \$INIT_PASS${NC}"
EOF
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Смените пароль на ${ARGOCD_PASSWORD}${NC}"
echo -e "${GREEN}  Локальный доступ: http://${NODES[vip]}:${ARGOCD_PORT} (admin | ${ARGOCD_PASSWORD})${NC}"
echo -e "${GREEN}  Внешний доступ:   https://${ARGOCD_HOST} (admin | ${ARGOCD_PASSWORD})${NC}"
echo -e "${GREEN}ArgoCD установлен${NC}"; echo -e "${GREEN}${NC}";
