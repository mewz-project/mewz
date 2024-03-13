#include <stdbool.h>
#include <string.h>

#include "lwip/init.h"
#include "lwip/dhcp.h"
#include "lwip/tcpip.h"
#include "lwip/autoip.h"
#include "lwip/opt.h"
#include "lwip/tcp.h"
#include "netif/ethernet.h"

#define MAX_PKT_SIZE 2048
#define MTU 1500

extern void transmit(u8_t *addr, u64_t size);
extern int socketPush(int fd, u8_t *addr, size_t size);
extern int *notifyAccepted(struct tcp_pcb *pcb, int fd);
extern void notifyReceived(int fd);
extern void notifyConnected(int fd);
extern void notifyClosed(int fd);
extern void notifyError(int fd, err_t err);

struct netif *netif;

err_t tx_send(struct netif *netif, struct pbuf *head) {
  // Copy data to pkt_buf)
  u8_t pkt_buf[MAX_PKT_SIZE];
  int offset = 0;
  for (struct pbuf *p = head; p != NULL; p = p->next) {
    int length = p->len;
    memcpy(&pkt_buf[offset], p->payload, length);
    offset += length;
  }

  transmit(pkt_buf, offset);
  return ERR_OK;
}

void rx_recv(void *data, u16_t size) {
  // Create pbuf in order to store read data
  struct pbuf* p = pbuf_alloc(PBUF_RAW, size, PBUF_POOL);
  p->payload = data;
  p->len = size;

  // Check Ethernet header & Pass data to lwIP
  const struct eth_hdr *ethhdr = p->payload;
  err_t ret;
  switch (htons(ethhdr->type)) {
    case ETHTYPE_IP:
    case ETHTYPE_ARP:
      ret = netif->input(p, netif);  // To be continued in lwIP.
      if (ret != ERR_OK) {
        pbuf_free(p);
      }
      break;
    default:
      pbuf_free(p);
  }
}

err_t init_netif(struct netif* netif) {
  netif->name[0] = 'I';
  netif->name[1] = 'F';
  netif->output = etharp_output;
  netif->linkoutput = tx_send;
  netif->mtu = MTU;    // TODO: set MTU
  netif->flags = NETIF_FLAG_ETHARP | NETIF_FLAG_LINK_UP;

  netif->hwaddr_len = ETHARP_HWADDR_LEN;
  for (int i = 0; i < netif->hwaddr_len; i++) {
    netif->hwaddr[i] = ((unsigned char*)netif->state)[i];
  }

  return ERR_OK;
}

err_t recv_callback(void *arg, struct tcp_pcb *tpcb,
                    struct pbuf *head, err_t err) {
    if (arg == NULL) {
      return ERR_OK;
    }

    int *fd = (int *)arg;

    if (head == NULL) {
      notifyClosed(*fd);
      return ERR_OK;
    }

    // Tell TCP data received
    for (struct pbuf *p = head; p != NULL; p = p->next) {
      tcp_recved(tpcb, p->len);

      // Push data to socket
      if (socketPush(*fd, (u8_t *)p->payload, p->len) < 0) {
        return ERR_MEM;
      }
    }

    pbuf_free(head);

    // Notify data received
    notifyReceived(*fd);

    return ERR_OK;
}

void error_callback(void *arg, err_t err) {
  if (arg == NULL) {
    return;
  }

  int *fd = (int *)arg;
  notifyError(*fd, err);
}

err_t accept_callback(void *arg, struct tcp_pcb *newpcb, err_t err) {
  if (arg == NULL) {
    tcp_abort(newpcb);
    return ERR_ABRT;
  }

  int *fd = (int *)arg;

  // TODO: handle error
  if (err != ERR_OK) {
    printf("accept_callback: err = {}\n", err);
    return err;
  }

  int *new_fd = notifyAccepted(newpcb, *fd);
  if (new_fd == NULL) {
    tcp_abort(newpcb);
    return ERR_ABRT;
  }

  if (socketPush(*fd, (u8_t *)new_fd, sizeof(int)) < 0) {
    return ERR_MEM;
  }

  tcp_recv(newpcb, recv_callback);
  tcp_err(newpcb, error_callback);

  return ERR_OK;
}

err_t connect_callback(void *arg, struct tcp_pcb *tpcb, err_t err) {
  if (arg == NULL) {
    tcp_abort(tpcb);
    return ERR_ABRT;
  }

  int *fd = (int *)arg;

  notifyConnected(*fd);

  return ERR_OK;
}

struct tcp_pcb *lwip_new_tcp_pcb(u8_t type) {
  struct tcp_pcb *new_tcp_pcb = tcp_new_ip_type(type);
}

void lwip_set_fd(struct tcp_pcb *pcb, s32_t *fd_ptr) {
  tcp_arg(pcb, fd_ptr);
}

err_t lwip_tcp_bind(struct tcp_pcb *pcb, u8_t ip[4], int port) {
  ip_addr_t *ipaddr = mem_malloc(sizeof(ip_addr_t));
  if (ipaddr == NULL) {
    return ERR_MEM;
  }
  IP4_ADDR(ipaddr, ip[0], ip[1], ip[2], ip[3]);
  return tcp_bind(pcb, ipaddr, port);
}

void lwip_accept(struct tcp_pcb *pcb) {
  tcp_accept(pcb, accept_callback);
}

u16_t lwip_tcp_sndbuf(struct tcp_pcb *pcb) {
  return tcp_sndbuf(pcb);
}

err_t lwip_send(struct tcp_pcb *pcb, u8_t *data, u16_t size) {
  err_t err = tcp_write(pcb, data, size, 1);
  if (err != ERR_OK) {
    return err;
  }

  return tcp_output(pcb);
}

err_t lwip_connect(struct tcp_pcb *pcb, u8_t ip[4], int port) {
  ip_addr_t *ipaddr = mem_malloc(sizeof(ip_addr_t));
  if (ipaddr == NULL) {
    return ERR_MEM;
  }
  IP4_ADDR(ipaddr, ip[0], ip[1], ip[2], ip[3]);
  return tcp_connect(pcb, ipaddr, port, connect_callback);
}

err_t lwip_tcp_close(struct tcp_pcb *pcb) {
  return tcp_close(pcb);
}

void lwip_unset_fd(struct tcp_pcb *pcb) {
  tcp_arg(pcb, NULL);
}

ip_addr_t *lwip_get_local_ip(struct tcp_pcb *pcb) {
  return &pcb->local_ip;
}

u16_t lwip_get_local_port(struct tcp_pcb *pcb) {
  return pcb->local_port;
}

ip_addr_t *lwip_get_remote_ip(struct tcp_pcb *pcb) {
  return &pcb->remote_ip;
}

u16_t lwip_get_remote_port(struct tcp_pcb *pcb) {
  return pcb->remote_port;
}

void init(u32_t ip, u32_t subnet, u32_t gateway_ip, char macaddr[6]) {
    lwip_init();

    ip_addr_t ipaddr, netmask, gateway;
    ipaddr.addr = ip;
    netmask.addr = subnet;
    gateway.addr = gateway_ip;

    // Specify TCP port
    u16_t tcp_port = 80;

    // Setup netif
    netif = malloc(sizeof(struct netif));
    netif_add(netif, &ipaddr, &netmask, &gateway,
              macaddr, init_netif, ethernet_input);
    netif_set_default(netif);
    netif_set_up(netif);

    // // Setup TCP
    // struct tcp_pcb *tcp_pcb1;
    // // Creates a new TCP protocol control block
    // tcp_pcb1 = tcp_new_ip_type(IPADDR_TYPE_ANY);
    // // Binds the connection to a local port number and IP address.
    // tcp_bind(tcp_pcb1, IP_ANY_TYPE, tcp_port);
    // // Set the state of the connection to be LISTEN
    // tcp_pcb1 = tcp_listen_with_backlog(tcp_pcb1, 1);
    // // Set callback function when accept TCP packet
    // tcp_accept(tcp_pcb1, accept_callback);

    // struct tcp_pcb *tcp_pcb2;
    // tcp_pcb2 = tcp_new_ip_type(IPADDR_TYPE_ANY);
    // ip_addr_t ipaddr2;
    // IP4_ADDR(&ipaddr2, 1, 1, 1, 1);
    // tcp_connect(tcp_pcb2, &ipaddr2, 80, send_hello);
}
